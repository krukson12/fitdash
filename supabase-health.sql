-- FitDash ← Apple Health (via iOS Shortcuts). Run once in Supabase → SQL Editor, after supabase.sql.

-- One personal key per user. The Shortcut sends it instead of logging in;
-- it can only add Health workouts/steps to that user's data.
create table if not exists public.fitdash_tokens (
  user_id    uuid        primary key default auth.uid() references auth.users on delete cascade,
  token      text        not null unique default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  created_at timestamptz not null default now()
);

alter table public.fitdash_tokens enable row level security;

drop policy if exists "own token" on public.fitdash_tokens;
create policy "own token" on public.fitdash_tokens
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

grant select, insert, delete on public.fitdash_tokens to authenticated;

-- Shortcuts may send numbers as text, with a comma decimal or a unit ("5,2 km"),
-- or a duration as h:mm:ss. Returns minutes for durations with ':'.
create or replace function public.fitdash_num(v text) returns numeric
language plpgsql immutable as $$
declare p text[];
begin
  if v is null or btrim(v) = '' then return null; end if;
  if v ~ '^\s*\d+:\d+(:\d+)?\s*$' then
    p := string_to_array(btrim(v), ':');
    if array_length(p, 1) = 3 then return p[1]::numeric * 60 + p[2]::numeric + p[3]::numeric / 60; end if;
    return p[1]::numeric + p[2]::numeric / 60;
  end if;
  return nullif(regexp_replace(replace(v, ',', '.'), '[^0-9.]', '', 'g'), '')::numeric;
end $$;

-- Called by the Shortcut: POST /rest/v1/rpc/fitdash_health
--   workout: {token, workout, start (ISO 8601), minutes, km}
--   steps:   {token, steps, day (ISO 8601)}
-- Records get t = 1, so anything edited or deleted in the app always wins,
-- and re-sending the same workout is a no-op.
create or replace function public.fitdash_health(
  token   text,
  workout text default null,
  start   text default null,
  minutes text default null,
  km      text default null,
  steps   text default null,
  day     text default null
) returns text
language plpgsql security definer set search_path = public as $$
declare
  uid   uuid;
  dur   numeric := fitdash_num(minutes);
  dist  numeric := fitdash_num(km);
  n     numeric := fitdash_num(steps);
  label text;
  d     text;
begin
  select t.user_id into uid from fitdash_tokens t where t.token = fitdash_health.token;
  if uid is null then raise exception 'invalid FitDash Health key' using errcode = '28000'; end if;

  if start is not null and workout is not null then
    if dur > 600 then dur := dur / 60; end if;        -- came in seconds
    if dist > 1000 then dist := dist / 1000; end if;  -- came in metres
    label := case
      when workout ~* 'run'       then 'Running'
      when workout ~* 'walk|hik'  then 'Walking'
      when workout ~* 'cycl|bik'  then 'Cycling'
      when workout ~* 'swim'      then 'Swimming'
      when workout ~* 'row'       then 'Rowing'
      else workout end;
    d := to_char(left(start, 10)::date, 'DD/MM/YYYY');
    insert into fitdash_records (user_id, coll, id, data, t)
    values (uid, 'cardio', 'hk-' || regexp_replace(start, '\D', '', 'g'),
            jsonb_build_object('type', label, 'dur', round(coalesce(dur, 0)), 'dist', round(coalesce(dist, 0), 2),
                               'date', d, 'c', (extract(epoch from start::timestamptz) * 1000)::bigint, 'source', 'health'),
            1)
    on conflict do nothing;
  end if;

  if n >= 10000 then
    d := to_char(coalesce(left(day, 10)::date, (now() at time zone 'Europe/Warsaw')::date), 'DD/MM/YYYY');
    insert into fitdash_records (user_id, coll, id, data, t)
    values (uid, 'habits', d || '~steps', '{"v": true}', 1)
    on conflict do nothing;
  end if;

  return 'ok';
end $$;

revoke all on function public.fitdash_health(text, text, text, text, text, text, text) from public;
grant execute on function public.fitdash_health(text, text, text, text, text, text, text) to anon, authenticated;
