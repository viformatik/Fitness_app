-- LOCAL CANDIDATE ONLY; NOT A MIGRATION AND NOT APPLIED TO ANY PROJECT.
-- Review against live schema and test on an isolated project before any rollout.
-- No user identifiers, IP addresses, queries or food/diary contents are stored.
-- The budget below is deliberately stricter than OFF's documented 10 search
-- requests per IP per minute. A successful reservation is never refunded.
-- Other applications sharing the same network egress can still exhaust OFF's
-- limit; failures must be treated as unavailable, not as complete results.

create table public.fitness_off_search_budget_v1 (
  kind text not null check (kind in ('discovery', 'batch')),
  reserved_at timestamptz not null
);
create index fitness_off_search_budget_v1_time_idx
  on public.fitness_off_search_budget_v1 (reserved_at);
alter table public.fitness_off_search_budget_v1 enable row level security;
revoke all on public.fitness_off_search_budget_v1 from public, anon, authenticated, service_role;

create function public.reserve_fitness_off_search_v1(p_kind text)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  window_now timestamptz;
  active_count bigint;
begin
  if p_kind is null or p_kind not in ('discovery', 'batch') then
    return false;
  end if;
  -- Serialize checks/inserts across all edge instances and both kinds.
  -- The lock is released only when the RPC transaction commits or rolls back.
  lock table public.fitness_off_search_budget_v1 in exclusive mode;
  window_now := clock_timestamp();
  delete from public.fitness_off_search_budget_v1
    where reserved_at <= window_now - interval '70 seconds';
  -- Discovery and batch searches may share an upstream per-IP budget even on
  -- different hosts. Count them together rather than assuming independence.
  select count(*) into active_count
    from public.fitness_off_search_budget_v1
    where reserved_at > window_now - interval '70 seconds';
  if active_count >= 8 then
    return false;
  end if;
  insert into public.fitness_off_search_budget_v1(kind, reserved_at)
    values (p_kind, window_now);
  return true;
end;
$$;
-- Only a server-side Supabase secret/service role can call the budget RPC.
-- This secret is read from the Edge runtime environment, never from a client.
revoke all on function public.reserve_fitness_off_search_v1(text) from public, anon, authenticated;
grant execute on function public.reserve_fitness_off_search_v1(text) to service_role;
