\set ON_ERROR_STOP on

begin;

create or replace function pg_temp.assert_true(p_ok boolean, p_message text)
returns void
language plpgsql
as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'assertion failed: %', p_message;
  end if;
end;
$$;

create or replace function pg_temp.assert_raises(p_sql text, p_message text)
returns void
language plpgsql
as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'assertion failed: expected error: %', p_message;
end;
$$;

insert into auth.users (
  id,
  instance_id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  raw_app_meta_data,
  raw_user_meta_data,
  created_at,
  updated_at
) values (
  '00000000-0000-0000-0000-000000000011',
  '00000000-0000-0000-0000-000000000000',
  'authenticated',
  'authenticated',
  'profile-claim-smoke@smoke.invalid',
  '',
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb,
  now(),
  now()
);

insert into public.players (id, display_name) values
  ('00000000-0000-0000-0000-000000000011', 'Profile Claim Smoke');

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000011',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select pg_temp.assert_true(
  (select profile_snapshot is null and snapshot_revision = 0
   from public.claim_profile(
     '10000000-0000-0000-0000-000000000001'::uuid
   )),
  'device A claims and atomically fetches the empty profile'
);

select pg_temp.assert_true(
  public.push_profile(
    '10000000-0000-0000-0000-000000000001'::uuid,
    '{"schema_version":1,"source":"device-a"}'::jsonb
  ),
  'the active device can push'
);

select pg_temp.assert_true(
  (select profile_snapshot =
            '{"schema_version":1,"source":"device-a"}'::jsonb
          and snapshot_revision = 1
   from public.claim_profile(
     '20000000-0000-0000-0000-000000000002'::uuid
   )),
  'device B claims and atomically fetches device A progress'
);

select pg_temp.assert_true(
  not public.push_profile(
    '10000000-0000-0000-0000-000000000001'::uuid,
    '{"schema_version":1,"source":"stale-device-a"}'::jsonb
  ),
  'device A is superseded immediately after device B claims'
);

select pg_temp.assert_true(
  (select profile_snapshot =
            '{"schema_version":1,"source":"device-a"}'::jsonb
          and snapshot_revision = 1
          and active_device_id =
            '20000000-0000-0000-0000-000000000002'::uuid
   from public.players
   where id = auth.uid()),
  'a superseded push leaves the claimed profile unchanged'
);

select pg_temp.assert_true(
  public.push_profile(
    '20000000-0000-0000-0000-000000000002'::uuid,
    '{"schema_version":1,"source":"device-b"}'::jsonb
  ),
  'the newly active device can push'
);

select pg_temp.assert_true(
  (select profile_snapshot =
            '{"schema_version":1,"source":"device-b"}'::jsonb
          and snapshot_revision = 2
          and snapshot_updated_at is not null
   from public.players
   where id = auth.uid()),
  'an accepted push stores the snapshot and advances server metadata'
);

select pg_temp.assert_raises(
  'select * from public.claim_profile(null::uuid)',
  'claim_profile rejects a null device'
);
select pg_temp.assert_raises(
  'select public.push_profile(null::uuid, ''{}''::jsonb)',
  'push_profile rejects a null device'
);
select pg_temp.assert_raises(
  'select public.push_profile('
    || quote_literal('20000000-0000-0000-0000-000000000002')
    || '::uuid, null::jsonb)',
  'push_profile rejects a null snapshot'
);
select pg_temp.assert_raises(
  'select public.push_profile('
    || quote_literal('20000000-0000-0000-0000-000000000002')
    || '::uuid, jsonb_build_object('
    || quote_literal('payload')
    || ', repeat('
    || quote_literal('x')
    || ', 262145)))',
  'the snapshot byte-size check rejects oversized JSON'
);

select set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000099',
  true
);
select pg_temp.assert_true(
  (select count(*) = 0
   from public.claim_profile(
     '30000000-0000-0000-0000-000000000003'::uuid
   )),
  'claim returns zero rows when the player row does not exist'
);

reset role;

select pg_temp.assert_true(
  has_table_privilege('authenticated', 'public.players', 'SELECT')
    and has_table_privilege('authenticated', 'public.players', 'INSERT')
    and has_table_privilege('authenticated', 'public.players', 'UPDATE'),
  'authenticated has the table privileges required by invoker RPCs'
);
select pg_temp.assert_true(
  has_function_privilege(
    'authenticated',
    'public.claim_profile(uuid)',
    'EXECUTE'
  ),
  'authenticated can execute claim_profile'
);
select pg_temp.assert_true(
  has_function_privilege(
    'authenticated',
    'public.push_profile(uuid,jsonb)',
    'EXECUTE'
  ),
  'authenticated can execute push_profile'
);
select pg_temp.assert_true(
  not has_function_privilege(
    'anon',
    'public.claim_profile(uuid)',
    'EXECUTE'
  ),
  'anon cannot execute claim_profile'
);
select pg_temp.assert_true(
  not has_function_privilege(
    'anon',
    'public.push_profile(uuid,jsonb)',
    'EXECUTE'
  ),
  'anon cannot execute push_profile'
);
select pg_temp.assert_true(
  not exists (
    select 1
    from pg_proc as p
    cross join lateral aclexplode(
      coalesce(p.proacl, acldefault('f', p.proowner))
    ) as acl
    where p.oid = 'public.claim_profile(uuid)'::regprocedure
      and acl.grantee = 0
      and acl.privilege_type = 'EXECUTE'
  ),
  'PUBLIC cannot execute claim_profile'
);
select pg_temp.assert_true(
  not exists (
    select 1
    from pg_proc as p
    cross join lateral aclexplode(
      coalesce(p.proacl, acldefault('f', p.proowner))
    ) as acl
    where p.oid = 'public.push_profile(uuid,jsonb)'::regprocedure
      and acl.grantee = 0
      and acl.privilege_type = 'EXECUTE'
  ),
  'PUBLIC cannot execute push_profile'
);

rollback;

\echo 'profile claim smoke checks passed'
