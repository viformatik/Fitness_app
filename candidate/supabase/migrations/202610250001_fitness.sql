-- Execute once in your own Supabase project SQL editor or `supabase db push`.
begin;
create table if not exists public.fitness_documents (
  user_id uuid not null references auth.users(id) on delete cascade,
  key text not null check (length(key) <= 256),
  payload jsonb, -- SQL NULL is a deletion tombstone; retain for offline devices.
  revision bigint not null default 1,
  updated_at timestamptz not null default now(),
  primary key (user_id, key)
);
alter table public.fitness_documents enable row level security;
drop policy if exists own_documents on public.fitness_documents;
create policy own_documents on public.fitness_documents for select to authenticated using (user_id = auth.uid());
revoke all on public.fitness_documents from anon, authenticated;
grant select on public.fitness_documents to authenticated;

-- Writes exclusively via compare-and-swap RPC; clients cannot bypass revision checks.
create or replace function public.write_fitness_document(p_key text, p_payload jsonb, p_expected bigint)
returns bigint language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); new_revision bigint;
begin
  if uid is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  if length(p_key) > 256 or not (
    p_key ~ '^(food_entries_|workout_entries_|water_intake_|steps_|workout_completed_)[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    or p_key in ('weight_entries','user_profile','quick_foods','recipes','reminders','smart_settings','meal_templates','custom_foods')
  ) then raise exception 'Invalid document key'; end if;
  if octet_length(coalesce(p_payload::text, '')) > 1048576 then raise exception 'Document too large'; end if;
  if p_expected is null then
    begin
      insert into public.fitness_documents(user_id,key,payload) values(uid,p_key,p_payload)
        returning revision into new_revision;
    exception when unique_violation then
      raise exception 'Concurrent document change' using errcode = '40001';
    end;
  else
    update public.fitness_documents set payload=p_payload, revision=revision+1, updated_at=now()
      where user_id=uid and key=p_key and revision=p_expected returning revision into new_revision;
    if not found then raise exception 'Concurrent document change' using errcode='40001'; end if;
  end if;
  return new_revision;
end $$;
revoke all on function public.write_fitness_document(text,jsonb,bigint) from public;
grant execute on function public.write_fitness_document(text,jsonb,bigint) to authenticated;

-- Atomic per-user limit, not an in-memory counter that resets across edge workers.
create table if not exists public.fitness_ai_quota (
  user_id uuid not null references auth.users(id) on delete cascade,
  bucket timestamptz not null,
  calls int not null default 0,
  primary key(user_id,bucket)
);
alter table public.fitness_ai_quota enable row level security;
revoke all on public.fitness_ai_quota from anon, authenticated;
create or replace function public.reserve_fitness_ai_call()
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
declare uid uuid := auth.uid(); current_calls int;
begin
  if uid is null then return false; end if;
  insert into public.fitness_ai_quota(user_id,bucket,calls)
    values(uid,date_trunc('hour',now()),1)
    on conflict(user_id,bucket) do update set calls=fitness_ai_quota.calls+1
    returning calls into current_calls;
  -- Prevent unbounded quota history. Retain seven days.
  delete from public.fitness_ai_quota where user_id=uid and bucket < now()-interval '7 days';
  return current_calls <= 15;
end $$;
revoke all on function public.reserve_fitness_ai_call() from public;
grant execute on function public.reserve_fitness_ai_call() to authenticated;
commit;
