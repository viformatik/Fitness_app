-- RECONSTRUCTED LOCAL CANDIDATE ONLY; NOT THE PREVIOUS TESTED SQL OR A RELEASE.
-- Do not apply to Supabase without independent backup/restore, actual-client
-- compatibility, grants, migration-history and rollback review. This replaces
-- a function only; it intentionally does not write existing rows at install.
-- It preserves compatible profile metadata when a legacy writer omits it,
-- but never confirms a goal whose old value/snapshot is absent or stale.
--
-- The application stores user_profile as a JSON *string* in jsonb. Missing
-- ageYears means "old client, preserve server value". Explicit null means
-- "new client deliberately has no age". Measurement/goal confirmation flags
-- are preserved only if the corresponding value is unchanged. When an old
-- client changes a value, it becomes unconfirmed rather than treating an old
-- default as a user-confirmed measurement or goal.
create or replace function public.write_fitness_document(p_key text, p_payload jsonb, p_expected bigint)
returns bigint language plpgsql security definer set search_path = public, pg_temp as $$
declare
  uid uuid := auth.uid();
  new_revision bigint;
  incoming_profile jsonb;
  existing_profile jsonb;
  existing_payload jsonb;
  merged boolean := false;
  age_text text;
  tracked_field record;
  goal_field record;
  valid_goal boolean;
begin
  if uid is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  if length(p_key) > 256 or not (
    p_key ~ '^(food_entries_|supplement_entries_|workout_entries_|water_intake_|steps_|workout_completed_)[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    or p_key ~ '^gym_session_[a-zA-Z0-9_-]{1,80}$'
    or p_key in ('weight_entries','user_profile','quick_foods','recipes','reminders','smart_settings','meal_templates','custom_foods','gym_plan_settings')
  ) then raise exception 'Invalid document key'; end if;
  if octet_length(coalesce(p_payload::text, '')) > 1048576 then raise exception 'Document too large'; end if;

  if p_key = 'user_profile' and p_payload is not null then
    if jsonb_typeof(p_payload) is distinct from 'string' then
      raise exception 'Invalid profile payload' using errcode = '22023';
    end if;
    begin
      incoming_profile := (p_payload #>> '{}')::jsonb;
    exception when invalid_text_representation then
      raise exception 'Invalid profile JSON' using errcode = '22023';
    end;
    if jsonb_typeof(incoming_profile) is distinct from 'object' then
      raise exception 'Invalid profile JSON' using errcode = '22023';
    end if;
    -- Reject an explicitly malformed new value, rather than making it look
    -- like a deliberate deletion. The old app never sends this field.
    if incoming_profile ? 'ageYears' and incoming_profile->'ageYears' <> 'null'::jsonb then
      age_text := incoming_profile->>'ageYears';
      if jsonb_typeof(incoming_profile->'ageYears') is distinct from 'number'
         or age_text !~ '^[0-9]+$' then
        raise exception 'Invalid age' using errcode = '22023';
      end if;
      if age_text::numeric < 1 or age_text::numeric > 120 then
        raise exception 'Invalid age' using errcode = '22023';
      end if;
    end if;
  end if;

  if p_expected is null then
    begin
      insert into public.fitness_documents(user_id,key,payload) values(uid,p_key,p_payload)
        returning revision into new_revision;
    exception when unique_violation then
      raise exception 'Concurrent document change' using errcode = 'PT409';
    end;
  else
    if p_key = 'user_profile' and p_payload is not null then
      -- Lock and check the expected revision before reading the protected
      -- metadata. A competing writer cannot change it between merge and CAS.
      select payload into existing_payload from public.fitness_documents
        where user_id=uid and key=p_key and revision=p_expected for update;
      if not found then raise exception 'Concurrent document change' using errcode = 'PT409'; end if;
      if existing_payload is not null and
          (not (incoming_profile ? 'ageYears') or
           not (incoming_profile ? 'targetWeightConfirmed') or
           not (incoming_profile ? 'heightConfirmed') or
           not (incoming_profile ? 'currentWeightConfirmed') or
           not (incoming_profile ? 'calorieGoalConfirmed') or
           not (incoming_profile ? 'proteinGoalConfirmed') or
           not (incoming_profile ? 'fatGoalConfirmed') or
           not (incoming_profile ? 'carbsGoalConfirmed') or
           not (incoming_profile ? 'waterGoalConfirmed') or
           not (incoming_profile ? 'stepsGoalConfirmed')) then
        if jsonb_typeof(existing_payload) is distinct from 'string' then
          raise exception 'Cannot safely merge existing profile' using errcode = '22023';
        end if;
        begin
          existing_profile := (existing_payload #>> '{}')::jsonb;
        exception when invalid_text_representation then
          raise exception 'Cannot safely merge existing profile' using errcode = '22023';
        end;
        if jsonb_typeof(existing_profile) is distinct from 'object' then
          raise exception 'Cannot safely merge existing profile' using errcode = '22023';
        end if;
        if not (incoming_profile ? 'ageYears') and existing_profile ? 'ageYears' then
          incoming_profile := jsonb_set(incoming_profile, '{ageYears}', existing_profile->'ageYears');
          merged := true;
        end if;
        for tracked_field in
          select * from (values
            ('heightConfirmed', 'height'),
            ('currentWeightConfirmed', 'currentWeight'),
            ('targetWeightConfirmed', 'targetWeight')
          ) as fields(flag_name, value_name)
        loop
          if not (incoming_profile ? tracked_field.flag_name) and existing_profile ? tracked_field.flag_name then
            if (incoming_profile->tracked_field.value_name) is not distinct from (existing_profile->tracked_field.value_name) then
              incoming_profile := jsonb_set(incoming_profile, array[tracked_field.flag_name], existing_profile->tracked_field.flag_name);
            else
              incoming_profile := jsonb_set(incoming_profile, array[tracked_field.flag_name], 'false'::jsonb);
            end if;
            merged := true;
          end if;
        end loop;

        -- A confirmation is bound to the exact goal values explicitly
        -- reviewed by the newer client. If an older client omits a flag,
        -- restore it only if the prior snapshot was complete and valid and
        -- its underlying number(s) are unchanged. Otherwise fail closed.
        -- A flag explicitly supplied by the writer is not silently rewritten;
        -- the current Dart model separately verifies its snapshots on read.
        for goal_field in
          select * from (values
            ('calorieGoalConfirmed', 'dailyCaloriesMin', 'calorieGoalConfirmedMin',
             'dailyCaloriesMax', 'calorieGoalConfirmedMax', false),
            ('proteinGoalConfirmed', 'targetProtein', 'proteinGoalConfirmedValue',
             null, null, false),
            ('fatGoalConfirmed', 'targetFat', 'fatGoalConfirmedValue',
             null, null, false),
            ('carbsGoalConfirmed', 'targetCarbs', 'carbsGoalConfirmedValue',
             null, null, false),
            ('waterGoalConfirmed', 'dailyWaterGoalMl', 'waterGoalConfirmedValue',
             null, null, true),
            ('stepsGoalConfirmed', 'dailyStepsGoal', 'stepsGoalConfirmedValue',
             null, null, true)
          ) as fields(flag_name, value_name, snapshot_name,
                      upper_name, upper_snapshot_name, strictly_positive)
        loop
          if not (incoming_profile ? goal_field.flag_name)
             and existing_profile ? goal_field.flag_name then
            valid_goal := existing_profile->goal_field.flag_name = 'true'::jsonb
              and jsonb_typeof(existing_profile->goal_field.value_name) = 'number'
              and (existing_profile->>goal_field.value_name) ~ '^[0-9]+$'
              and existing_profile ? goal_field.snapshot_name
              and (existing_profile->goal_field.snapshot_name)
                  is not distinct from (existing_profile->goal_field.value_name)
              and (incoming_profile->goal_field.value_name)
                  is not distinct from (existing_profile->goal_field.value_name);
            if valid_goal and goal_field.strictly_positive then
              valid_goal := (existing_profile->>goal_field.value_name)::numeric > 0;
            end if;
            if valid_goal and goal_field.upper_name is not null then
              valid_goal := jsonb_typeof(existing_profile->goal_field.upper_name) = 'number'
                and (existing_profile->>goal_field.upper_name) ~ '^[0-9]+$'
                and existing_profile ? goal_field.upper_snapshot_name
                and (existing_profile->goal_field.upper_snapshot_name)
                    is not distinct from (existing_profile->goal_field.upper_name)
                and (incoming_profile->goal_field.upper_name)
                    is not distinct from (existing_profile->goal_field.upper_name);
              if valid_goal then
                valid_goal := (existing_profile->>goal_field.upper_name)::numeric >=
                              (existing_profile->>goal_field.value_name)::numeric;
              end if;
            end if;
            if valid_goal is true then
              incoming_profile := jsonb_set(incoming_profile, array[goal_field.flag_name], 'true'::jsonb);
              incoming_profile := jsonb_set(incoming_profile, array[goal_field.snapshot_name],
                                            existing_profile->goal_field.snapshot_name);
              if goal_field.upper_snapshot_name is not null then
                incoming_profile := jsonb_set(incoming_profile, array[goal_field.upper_snapshot_name],
                                              existing_profile->goal_field.upper_snapshot_name);
              end if;
            else
              incoming_profile := jsonb_set(incoming_profile, array[goal_field.flag_name], 'false'::jsonb);
              incoming_profile := incoming_profile - goal_field.snapshot_name;
              if goal_field.upper_snapshot_name is not null then
                incoming_profile := incoming_profile - goal_field.upper_snapshot_name;
              end if;
            end if;
            merged := true;
          end if;
        end loop;
      end if;
      if merged then p_payload := to_jsonb(incoming_profile::text); end if;
      if octet_length(coalesce(p_payload::text, '')) > 1048576 then
        raise exception 'Document too large';
      end if;
    end if;
    update public.fitness_documents set payload=p_payload, revision=revision+1, updated_at=now()
      where user_id=uid and key=p_key and revision=p_expected returning revision into new_revision;
    if not found then raise exception 'Concurrent document change' using errcode='PT409'; end if;
  end if;
  return new_revision;
end $$;
-- CREATE OR REPLACE retains grants, but assert the same public/authenticated
-- contract as the existing local migration; no direct table writes are added.
revoke all on function public.write_fitness_document(text,jsonb,bigint) from public;
grant execute on function public.write_fitness_document(text,jsonb,bigint) to authenticated;
