-- Shared, privacy-preserving quota for anonymous Open Food Facts search.
-- The Edge function sends a salted SHA-256 hash of the client IP, never the IP.
create table if not exists public.fitness_food_search_quota (
  key_hash text not null check (char_length(key_hash) between 1 and 80),
  bucket timestamptz not null,
  calls integer not null default 1 check (calls > 0),
  primary key (key_hash, bucket)
);

alter table public.fitness_food_search_quota enable row level security;
revoke all on table public.fitness_food_search_quota from public, anon, authenticated;

create or replace function public.reserve_fitness_food_search_call(p_key text)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  bucket_time timestamptz := date_trunc('minute', now());
  ip_calls integer;
  global_calls integer;
begin
  if p_key is null or p_key !~ '^[a-f0-9]{64}$' then
    return false;
  end if;

  insert into public.fitness_food_search_quota(key_hash, bucket, calls)
  values ('ip:' || p_key, bucket_time, 1)
  on conflict (key_hash, bucket) do update
    set calls = public.fitness_food_search_quota.calls + 1
  returning calls into ip_calls;

  insert into public.fitness_food_search_quota(key_hash, bucket, calls)
  values ('global', bucket_time, 1)
  on conflict (key_hash, bucket) do update
    set calls = public.fitness_food_search_quota.calls + 1
  returning calls into global_calls;

  delete from public.fitness_food_search_quota
  where bucket < now() - interval '2 hours';

  -- Below Open Food Facts' documented 10 search requests/minute/IP.
  return ip_calls <= 8 and global_calls <= 8;
end;
$$;

revoke all on function public.reserve_fitness_food_search_call(text) from public;
grant execute on function public.reserve_fitness_food_search_call(text)
  to anon, authenticated, service_role;
