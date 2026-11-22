-- Non-destructive forward fix: business CAS conflicts return PT409 (HTTP 409).
-- SQLSTATE 40001 is retryable and can trigger endless PostgREST 14 retries.
-- Authentication, RLS, CAS conditions, document keys and grants are unchanged.
create or replace function public.write_fitness_document(p_key text, p_payload jsonb, p_expected bigint)
returns bigint language plpgsql security definer set search_path = public, pg_temp as $$
declare uid uuid := auth.uid(); new_revision bigint;
begin
  if uid is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  if length(p_key) > 256 or not (
    p_key ~ '^(food_entries_|supplement_entries_|workout_entries_|water_intake_|steps_|workout_completed_)[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    or p_key ~ '^gym_session_[a-zA-Z0-9_-]{1,80}$'
    or p_key in ('weight_entries','user_profile','quick_foods','recipes','reminders','smart_settings','meal_templates','custom_foods','gym_plan_settings')
  ) then raise exception 'Invalid document key'; end if;
  if octet_length(coalesce(p_payload::text, '')) > 1048576 then raise exception 'Document too large'; end if;
  if p_expected is null then
    begin
      insert into public.fitness_documents(user_id,key,payload) values(uid,p_key,p_payload)
        returning revision into new_revision;
    exception when unique_violation then
      raise exception 'Concurrent document change' using errcode = 'PT409';
    end;
  else
    update public.fitness_documents set payload=p_payload, revision=revision+1, updated_at=now()
      where user_id=uid and key=p_key and revision=p_expected returning revision into new_revision;
    if not found then raise exception 'Concurrent document change' using errcode='PT409'; end if;
  end if;
  return new_revision;
end $$;
revoke all on function public.write_fitness_document(text,jsonb,bigint) from public;
grant execute on function public.write_fitness_document(text,jsonb,bigint) to authenticated;
