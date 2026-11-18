-- LOCAL CANDIDATE ONLY. Do not apply to production until backups, live schema,
-- grants, PostgREST, old/new clients and deployment order have been verified.
-- Sleep uses a separate table: older clients validate every row from
-- fitness_documents and would fail sync on a new key in that table.
begin;
create table if not exists public.fitness_sleep_documents (
  user_id uuid not null references auth.users(id) on delete cascade,
  key text not null check (length(key) <= 30),
  payload jsonb, -- SQL NULL is a revisioned deletion tombstone.
  revision bigint not null default 1,
  updated_at timestamptz not null default now(),
  primary key (user_id, key)
);
alter table public.fitness_sleep_documents enable row level security;
drop policy if exists own_sleep_documents on public.fitness_sleep_documents;
create policy own_sleep_documents on public.fitness_sleep_documents
  for select to authenticated using (user_id = auth.uid());
revoke all on public.fitness_sleep_documents from public, anon, authenticated;
grant select on public.fitness_sleep_documents to authenticated;

create or replace function public.write_fitness_sleep_document(
  p_key text, p_payload jsonb, p_expected bigint
) returns bigint language plpgsql security definer set search_path = public, pg_temp as $$
declare
  uid uuid := auth.uid();
  day_text text;
  parsed_day date;
  body jsonb;
  minutes_text text;
  field_count integer;
  next_revision bigint;
begin
  if uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if p_key is null or p_key !~ '^sleep_day_[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'Invalid sleep key' using errcode = '22023';
  end if;
  day_text := substring(p_key from 11);
  begin
    parsed_day := day_text::date;
  exception when others then
    raise exception 'Invalid sleep date' using errcode = '22023';
  end;
  if to_char(parsed_day, 'YYYY-MM-DD') is distinct from day_text then
    raise exception 'Invalid sleep date' using errcode = '22023';
  end if;
  if octet_length(coalesce(p_payload::text, '')) > 4096 then
    raise exception 'Sleep document too large' using errcode = '22023';
  end if;
  if p_payload is not null then
    if jsonb_typeof(p_payload) is distinct from 'string' then
      raise exception 'Invalid sleep payload' using errcode = '22023';
    end if;
    begin
      body := (p_payload #>> '{}')::jsonb;
    exception when invalid_text_representation then
      raise exception 'Invalid sleep JSON' using errcode = '22023';
    end;
    if jsonb_typeof(body) is distinct from 'object' then
      raise exception 'Invalid sleep JSON' using errcode = '22023';
    end if;
    select count(*) into field_count from jsonb_object_keys(body);
    minutes_text := body->>'minutes';
    if field_count <> 4 or not (body ?& array['version','day','minutes','source'])
       or body->'version' is distinct from '1'::jsonb
       or body->>'day' is distinct from day_text
       or body->>'source' is distinct from 'manual'
       or jsonb_typeof(body->'minutes') is distinct from 'number'
       or minutes_text !~ '^(0|[1-9][0-9]{0,3})$' then
      raise exception 'Invalid sleep data' using errcode = '22023';
    end if;
    if minutes_text::numeric > 1440 then
      raise exception 'Invalid sleep duration' using errcode = '22023';
    end if;
  end if;
  if p_expected is null then
    begin
      insert into public.fitness_sleep_documents(user_id,key,payload)
        values(uid,p_key,p_payload) returning revision into next_revision;
    exception when unique_violation then
      raise exception 'Concurrent document change' using errcode = 'PT409';
    end;
  else
    update public.fitness_sleep_documents
      set payload=p_payload, revision=revision+1, updated_at=now()
      where user_id=uid and key=p_key and revision=p_expected
      returning revision into next_revision;
    if not found then
      raise exception 'Concurrent document change' using errcode = 'PT409';
    end if;
  end if;
  return next_revision;
end $$;
revoke all on function public.write_fitness_sleep_document(text,jsonb,bigint) from public, anon, authenticated;
grant execute on function public.write_fitness_sleep_document(text,jsonb,bigint) to authenticated;
commit;
