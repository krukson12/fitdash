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

-- Dates from Shortcuts should be ISO 8601; fall back instead of failing.
create or replace function public.fitdash_ts(v text) returns timestamptz
language plpgsql stable as $$
begin
  return v::timestamptz;
exception when others then
  return null;
end $$;

-- Log of what the Shortcuts sent and what happened, shown in the app's Health card.
create table if not exists public.fitdash_health_log (
  id      bigint generated always as identity primary key,
  user_id uuid        not null references auth.users on delete cascade,
  at      timestamptz not null default now(),
  payload jsonb,
  result  text
);
create index if not exists fitdash_health_log_user on public.fitdash_health_log (user_id, id desc);
alter table public.fitdash_health_log enable row level security;
drop policy if exists "own log" on public.fitdash_health_log;
create policy "own log" on public.fitdash_health_log for select to authenticated using (user_id = auth.uid());
grant select on public.fitdash_health_log to authenticated;

drop function if exists public.fitdash_health(text, text, text, text, text, text, text);
drop function if exists public.fitdash_health(text, text, text, text, text, text, text, text, text, text, text, text);

-- Does the import for one user. Only cardio-type workouts are imported (strength
-- sessions are logged by hand in the app). Records get t = 1, so anything edited or
-- deleted in the app always wins, and re-sending the same item is a no-op.
create or replace function public.fitdash_health_apply(
  uid uuid, workout text, start text, finish text, minutes text, km text,
  steps text, day text, w_name text, w_type text, w_value text, w_unit text
) returns text
language plpgsql set search_path = public as $$
declare
  ts0   timestamptz := fitdash_ts(start);
  ts1   timestamptz := fitdash_ts(finish);
  dur   numeric := fitdash_num(minutes);
  dist  numeric := fitdash_num(km);
  val   numeric := fitdash_num(w_value);
  n     numeric := fitdash_num(steps);
  hint  text := concat_ws(' ', workout, w_name, w_type);
  label text;
  d     text;
begin
  if steps is not null then
    n := coalesce(val, n);   -- the sample's Value property is cleaner than its text form
    d := to_char(coalesce(fitdash_ts(day) at time zone 'Europe/Warsaw', now() at time zone 'Europe/Warsaw')::date, 'DD/MM/YYYY');
    if day ~ '^\d{4}-\d{2}-\d{2}' then d := to_char(left(day, 10)::date, 'DD/MM/YYYY'); end if;
    if n >= 10000 then
      insert into fitdash_records (user_id, coll, id, data, t)
      values (uid, 'habits', d || '~steps', '{"v": true}', 1)
      on conflict do nothing;
      return format('ok: %s steps on %s, habit ticked', round(n), d);
    end if;
    return format('ok: %s steps on %s, under 10000', coalesce(round(n)::text, '?'), d);
  end if;

  if start is null then return 'nothing to import'; end if;

  if ts0 is null then
    return format('error: could not read start date "%s" (workout "%s")', start, hint);
  end if;

  label := case
    when hint ~* 'run|bieg'                         then 'Running'
    when hint ~* 'walk|hik|ch[oó]d|spacer|w[eę]dr'  then 'Walking'
    when hint ~* 'cycl|bik|rower|kolar'             then 'Cycling'
    when hint ~* 'swim|p[lł]yw'                     then 'Swimming'
    when hint ~* 'row|wios[lł]'                     then 'Rowing'
    else null end;
  if label is null then
    return format('skipped (not cardio): "%s" value "%s" unit "%s"', hint, w_value, w_unit);
  end if;

  if ts1 is not null and ts1 > ts0 then
    dur := extract(epoch from ts1 - ts0) / 60;
  elsif dur > 600 then
    dur := dur / 60;                                   -- came in seconds
  end if;
  if dist is null and val is not null then
    if    w_unit ~* '^\s*(km|kilom)' then dist := val;
    elsif w_unit ~* '^\s*mi(\s*$|le)' then dist := val * 1.609344;
    elsif w_unit ~* '^\s*m(et|\s*$)' then dist := val / 1000;
    end if;
  end if;
  if dist > 1000 then dist := dist / 1000; end if;     -- came in metres

  d := to_char((case when start ~ '^\d{4}-\d{2}-\d{2}' then left(start, 10)::date else (ts0 at time zone 'Europe/Warsaw')::date end), 'DD/MM/YYYY');
  insert into fitdash_records (user_id, coll, id, data, t)
  values (uid, 'cardio', 'hk-' || to_char(ts0 at time zone 'UTC', 'YYYYMMDDHH24MISS'),
          jsonb_build_object('type', label, 'dur', round(coalesce(dur, 0)), 'dist', round(coalesce(dist, 0), 2),
                             'date', d, 'c', (extract(epoch from ts0) * 1000)::bigint, 'source', 'health'),
          1)
  on conflict do nothing;

  return format('ok: %s, %s min, %s km (%s)', label, round(coalesce(dur, 0)), round(coalesce(dist, 0), 2), d);
end $$;

-- Called by the Shortcuts: POST /rest/v1/rpc/fitdash_health
--   steps:   {token, steps, w_value, day}
--   workout: {token, start, finish, workout, w_name, w_type, w_value, w_unit, minutes, km}
--   ping:    {token, ping}   (sent once at the end of a Shortcut run)
create or replace function public.fitdash_health(
  token   text,
  workout text default null,
  start   text default null,
  finish  text default null,
  minutes text default null,
  km      text default null,
  steps   text default null,
  day     text default null,
  w_name  text default null,
  w_type  text default null,
  w_value text default null,
  w_unit  text default null,
  ping    text default null
) returns text
language plpgsql security definer set search_path = public as $$
declare
  uid uuid;
  res text;
begin
  select t.user_id into uid from fitdash_tokens t where t.token = fitdash_health.token;
  if uid is null then raise exception 'invalid FitDash Health key' using errcode = '28000'; end if;

  if ping is not null and start is null and steps is null then
    res := 'run finished: ' || ping;
  else
    begin
      res := fitdash_health_apply(uid, workout, start, finish, minutes, km, steps, day, w_name, w_type, w_value, w_unit);
    exception when others then
      res := 'error: ' || sqlerrm;
    end;
  end if;

  insert into fitdash_health_log (user_id, payload, result)
  values (uid, jsonb_strip_nulls(jsonb_build_object('workout', workout, 'start', start, 'finish', finish, 'minutes', minutes,
          'km', km, 'steps', steps, 'day', day, 'w_name', w_name, 'w_type', w_type, 'w_value', w_value, 'w_unit', w_unit, 'ping', ping)), res);
  delete from fitdash_health_log l where l.user_id = uid
    and l.id not in (select id from fitdash_health_log where user_id = uid order by id desc limit 80);
  return res;
end $$;

revoke all on function public.fitdash_health_apply(uuid, text, text, text, text, text, text, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.fitdash_health(text, text, text, text, text, text, text, text, text, text, text, text, text) from public;
grant execute on function public.fitdash_health(text, text, text, text, text, text, text, text, text, text, text, text, text) to anon, authenticated;
