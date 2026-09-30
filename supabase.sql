-- FitDash sync table. Run once in Supabase → SQL Editor.
-- One row per item (exercise, cardio, body weight, todo, habit-per-day).
-- Newest edit wins (by client timestamp t); deletes are kept as tombstones (del = true).

create table if not exists public.fitdash_records (
  user_id    uuid        not null default auth.uid() references auth.users on delete cascade,
  coll       text        not null,
  id         text        not null,
  data       jsonb,
  t          bigint      not null,
  del        boolean     not null default false,
  updated_at timestamptz not null default clock_timestamp(),
  primary key (user_id, coll, id)
);

create index if not exists fitdash_records_pull on public.fitdash_records (user_id, updated_at);

alter table public.fitdash_records enable row level security;

drop policy if exists "own records" on public.fitdash_records;
create policy "own records" on public.fitdash_records
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

grant select, insert, update on public.fitdash_records to authenticated;

-- Ignore stale writes (older t) and stamp server time for incremental pulls.
create or replace function public.fitdash_records_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' and new.t < old.t then
    return null;
  end if;
  new.updated_at := clock_timestamp();
  return new;
end $$;

drop trigger if exists fitdash_records_guard on public.fitdash_records;
create trigger fitdash_records_guard
  before insert or update on public.fitdash_records
  for each row execute function public.fitdash_records_guard();
