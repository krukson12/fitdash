-- FitDash ← Strava. Run once in Supabase → SQL Editor, after supabase.sql.
-- Before running: replace the two PASTE_… values below with the Client ID and
-- Client Secret from https://www.strava.com/settings/api

create extension if not exists http with schema extensions;

-- App-wide settings; readable only through the functions below.
create table if not exists public.fitdash_config (
  key   text primary key,
  value text not null
);
alter table public.fitdash_config enable row level security;

insert into public.fitdash_config (key, value) values
  ('strava_client_id',     'PASTE_CLIENT_ID'),
  ('strava_client_secret', 'PASTE_CLIENT_SECRET')
on conflict (key) do update set value = excluded.value;

-- One Strava connection per user; tokens never leave the database.
create table if not exists public.fitdash_strava (
  user_id       uuid primary key references auth.users on delete cascade,
  athlete_id    bigint,
  athlete_name  text,
  refresh_token text not null,
  access_token  text,
  expires_at    timestamptz,
  last_sync     timestamptz,
  last_result   text
);
alter table public.fitdash_strava enable row level security;

-- What the app needs to draw the Strava card.
create or replace function public.fitdash_strava_status() returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'client_id',   (select value from fitdash_config where key = 'strava_client_id' and value !~ '^PASTE'),
    'connected',   s.user_id is not null,
    'athlete',     s.athlete_name,
    'last_sync',   s.last_sync,
    'last_result', s.last_result)
  from (select auth.uid() as uid) u
  left join fitdash_strava s on s.user_id = u.uid;
$$;

-- Finish "Connect Strava": swap the one-time code for tokens.
create or replace function public.fitdash_strava_connect(code text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid := auth.uid();
  cid text; sec text; r extensions.http_response; j jsonb;
begin
  if uid is null then raise exception 'not signed in'; end if;
  select value into cid from fitdash_config where key = 'strava_client_id';
  select value into sec from fitdash_config where key = 'strava_client_secret';
  r := extensions.http_post('https://www.strava.com/oauth/token',
        format('client_id=%s&client_secret=%s&code=%s&grant_type=authorization_code', extensions.urlencode(cid), extensions.urlencode(sec), extensions.urlencode(code)),
        'application/x-www-form-urlencoded');
  if r.status <> 200 then
    raise exception 'Strava refused the connection (%): %', r.status, left(r.content, 200);
  end if;
  j := r.content::jsonb;
  insert into fitdash_strava (user_id, athlete_id, athlete_name, refresh_token, access_token, expires_at)
  values (uid, (j->'athlete'->>'id')::bigint, concat_ws(' ', j->'athlete'->>'firstname', j->'athlete'->>'lastname'),
          j->>'refresh_token', j->>'access_token', to_timestamp((j->>'expires_at')::bigint))
  on conflict (user_id) do update set athlete_id = excluded.athlete_id, athlete_name = excluded.athlete_name,
    refresh_token = excluded.refresh_token, access_token = excluded.access_token, expires_at = excluded.expires_at,
    last_sync = null, last_result = null;
  return 'ok';
end $$;

-- Fetch recent Strava activities and add the cardio ones to the user's records.
-- First run looks back 30 days, later runs re-check the last 3 days. Records get
-- t = 1 and "on conflict do nothing": re-syncing never duplicates, and anything
-- deleted in the app stays deleted.
create or replace function public.fitdash_strava_sync() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid := auth.uid();
  s fitdash_strava; cid text; sec text; r extensions.http_response; j jsonb; a jsonb;
  since bigint; st text; label text; got int; added int := 0; seen int := 0; msg text;
begin
  if uid is null then raise exception 'not signed in'; end if;
  select * into s from fitdash_strava where user_id = uid;
  if not found then return jsonb_build_object('connected', false); end if;

  if s.access_token is null or s.expires_at < now() + interval '2 minutes' then
    select value into cid from fitdash_config where key = 'strava_client_id';
    select value into sec from fitdash_config where key = 'strava_client_secret';
    r := extensions.http_post('https://www.strava.com/oauth/token',
          format('client_id=%s&client_secret=%s&grant_type=refresh_token&refresh_token=%s', extensions.urlencode(cid), extensions.urlencode(sec), extensions.urlencode(s.refresh_token)),
          'application/x-www-form-urlencoded');
    if r.status <> 200 then
      msg := format('error: Strava login expired (%s) — reconnect', r.status);
      update fitdash_strava set last_result = msg where user_id = uid;
      return jsonb_build_object('connected', true, 'error', msg);
    end if;
    j := r.content::jsonb;
    s.access_token := j->>'access_token';
    update fitdash_strava set access_token = s.access_token, refresh_token = coalesce(j->>'refresh_token', refresh_token),
      expires_at = to_timestamp((j->>'expires_at')::bigint) where user_id = uid;
  end if;

  since := extract(epoch from coalesce(s.last_sync - interval '3 days', now() - interval '30 days'))::bigint;
  r := extensions.http(('GET', format('https://www.strava.com/api/v3/athlete/activities?after=%s&per_page=100', since),
             array[extensions.http_header('Authorization', 'Bearer ' || s.access_token)], null, null)::extensions.http_request);
  if r.status <> 200 then
    msg := format('error: Strava answered %s: %s', r.status, left(r.content, 150));
    update fitdash_strava set last_result = msg where user_id = uid;
    return jsonb_build_object('connected', true, 'error', msg);
  end if;

  for a in select * from jsonb_array_elements(r.content::jsonb) loop
    seen := seen + 1;
    st := coalesce(a->>'sport_type', a->>'type', '');
    label := case
      when st ~* 'run'       then 'Running'
      when st ~* 'walk|hike' then 'Walking'
      when st ~* 'ride'      then 'Cycling'
      when st ~* 'swim'      then 'Swimming'
      when st ~* 'row'       then 'Rowing'
      else null end;
    continue when label is null;
    insert into fitdash_records (user_id, coll, id, data, t)
    values (uid, 'cardio', 'strava-' || (a->>'id'),
            jsonb_build_object('type', label,
              'dur',  round(coalesce((a->>'moving_time')::numeric, 0) / 60),
              'dist', round(coalesce((a->>'distance')::numeric, 0) / 1000, 2),
              'date', to_char(left(a->>'start_date_local', 10)::date, 'DD/MM/YYYY'),
              'c',    (extract(epoch from (a->>'start_date')::timestamptz) * 1000)::bigint,
              'name', a->>'name', 'source', 'strava'),
            1)
    on conflict do nothing;
    get diagnostics got = row_count;
    added := added + got;
  end loop;

  msg := format('ok: %s new, %s activities checked', added, seen);
  update fitdash_strava set last_sync = now(), last_result = msg where user_id = uid;
  return jsonb_build_object('connected', true, 'added', added, 'seen', seen, 'result', msg);
end $$;

create or replace function public.fitdash_strava_disconnect() returns text
language sql security definer set search_path = public as $$
  delete from fitdash_strava where user_id = auth.uid();
  select 'ok'::text;
$$;

revoke all on function public.fitdash_strava_status()      from public, anon;
revoke all on function public.fitdash_strava_connect(text) from public, anon;
revoke all on function public.fitdash_strava_sync()        from public, anon;
revoke all on function public.fitdash_strava_disconnect()  from public, anon;
grant execute on function public.fitdash_strava_status()      to authenticated;
grant execute on function public.fitdash_strava_connect(text) to authenticated;
grant execute on function public.fitdash_strava_sync()        to authenticated;
grant execute on function public.fitdash_strava_disconnect()  to authenticated;
