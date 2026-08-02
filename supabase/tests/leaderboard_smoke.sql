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

create temporary table smoke_users (
  id uuid primary key,
  display_name text not null,
  kind text not null
);

insert into smoke_users (id, display_name, kind) values
  ('00000000-0000-0000-0000-000000000001', 'Smoke Lower Friend', 'friend'),
  ('00000000-0000-0000-0000-000000000002', 'Smoke Above One', 'competitor'),
  ('00000000-0000-0000-0000-000000000003', 'Smoke Above Two', 'competitor'),
  ('00000000-0000-0000-0000-000000000004', 'Smoke Above Three', 'competitor'),
  ('00000000-0000-0000-0000-000000000005', 'Smoke Me', 'me'),
  ('00000000-0000-0000-0000-000000000006', 'Smoke Tie', 'competitor'),
  ('00000000-0000-0000-0000-000000000007', 'Smoke Other', 'competitor'),
  ('00000000-0000-0000-0000-000000000009', 'Smoke Higher Friend', 'friend'),
  ('00000000-0000-0000-0000-000000000010', 'Smoke Stranger', 'stranger');

insert into smoke_users (id, display_name, kind)
select gen_random_uuid(), 'Smoke Bulk ' || n, 'bulk'
from generate_series(1, 105) as n;

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
)
select
  id,
  '00000000-0000-0000-0000-000000000000',
  'authenticated',
  'authenticated',
  replace(id::text, '-', '') || '@smoke.invalid',
  '',
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb,
  now(),
  now()
from smoke_users;

insert into players (id, display_name)
select id, display_name from smoke_users;

-- Explicit lower/me and me/higher edges prove both canonical edge directions.
insert into friendships (a, b) values
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000005'),
  ('00000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000009');

-- A large friend graph makes the friends-board 100-row clamp observable.
insert into friendships (a, b)
select
  least(id, '00000000-0000-0000-0000-000000000005'::uuid),
  greatest(id, '00000000-0000-0000-0000-000000000005'::uuid)
from smoke_users
where kind = 'bulk';

-- Daily rank tie: four distinct scores above the caller and a tie at rank 5.
insert into scores (
  player_id, utc_date, difficulty, score, highest_tier, season
) values
  ('00000000-0000-0000-0000-000000000002', current_date - 1, 'easy', 500, 1, 42),
  ('00000000-0000-0000-0000-000000000003', current_date - 1, 'easy', 400, 1, 42),
  ('00000000-0000-0000-0000-000000000004', current_date - 1, 'easy', 300, 1, 42),
  ('00000000-0000-0000-0000-000000000007', current_date - 1, 'easy', 200, 1, 42),
  ('00000000-0000-0000-0000-000000000005', current_date - 1, 'easy', 100, 1, 42),
  ('00000000-0000-0000-0000-000000000006', current_date - 1, 'easy', 100, 1, 42),
  ('00000000-0000-0000-0000-000000000010', current_date - 1, 'easy', 60, 1, 42),
  ('00000000-0000-0000-0000-000000000001', current_date - 1, 'easy', 50, 1, 42),
  ('00000000-0000-0000-0000-000000000009', current_date - 1, 'easy', 40, 1, 42),
  ('00000000-0000-0000-0000-000000000005', current_date - 2, 'hard', 50, 1, 42),
  ('00000000-0000-0000-0000-000000000005', current_date - 1, 'hard', 9999, 1, 41);

insert into scores (
  player_id, utc_date, difficulty, score, highest_tier, season
)
select id, current_date - 1, 'easy', 25, 1, 41
from smoke_users
where kind = 'bulk'
limit 1;

-- Period rank tie at the same payout boundary; the caller must not become #1.
insert into scores (
  player_id, utc_date, difficulty, score, highest_tier, season
) values
  ('00000000-0000-0000-0000-000000000002', current_date - 3, 'medium', 500, 1, 42),
  ('00000000-0000-0000-0000-000000000003', current_date - 3, 'medium', 400, 1, 42),
  ('00000000-0000-0000-0000-000000000004', current_date - 3, 'medium', 300, 1, 42),
  ('00000000-0000-0000-0000-000000000007', current_date - 3, 'medium', 200, 1, 42),
  ('00000000-0000-0000-0000-000000000005', current_date - 3, 'medium', 100, 1, 42),
  ('00000000-0000-0000-0000-000000000006', current_date - 3, 'medium', 100, 1, 42);

-- Separate season for limit and friends visibility checks.
insert into scores (
  player_id, utc_date, difficulty, score, highest_tier, season
)
select id, current_date - 1, 'legendary', 1000 - row_number() over (), 1, 43
from smoke_users;

set local role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000005',
  true
);
select set_config('request.jwt.claim.role', 'authenticated', true);

select pg_temp.assert_true(
  (select rank = 5
   from my_daily_ranks(current_date - 1, current_date - 1, 42)
   where utc_date = current_date - 1 and difficulty = 'easy'),
  'my_daily_ranks ranks all players before filtering the caller'
);

select pg_temp.assert_true(
  (select rank = 5
   from my_period_ranks(current_date - 3, current_date - 1, 42)
   where difficulty = 'medium'),
  'my_period_ranks ranks all players before filtering the caller'
);

select pg_temp.assert_true(
  (select count(*) = 2
   from my_daily_ranks(current_date - 2, current_date - 1, 42)),
  'daily caller ranks respect date and season filters'
);

select pg_temp.assert_true(
  (select count(*) = 100
   from leaderboard(current_date - 1, 'legendary', 43, null)),
  'daily NULL limit clamps to 100'
);
select pg_temp.assert_true(
  (select count(*) = 1
   from leaderboard(current_date - 1, 'legendary', 43, 0)),
  'daily zero limit clamps to 1'
);
select pg_temp.assert_true(
  (select count(*) = 1
   from leaderboard(current_date - 1, 'legendary', 43, -100)),
  'daily negative limit clamps to 1'
);
select pg_temp.assert_true(
  (select count(*) = 100
   from leaderboard(current_date - 1, 'legendary', 43, 1000000)),
  'daily huge limit clamps to 100'
);

select pg_temp.assert_true(
  (select count(*) = 100
   from leaderboard_period(
     'legendary', current_date - 1, current_date - 1, 43, null
   )),
  'period NULL limit clamps to 100'
);
select pg_temp.assert_true(
  (select count(*) = 1
   from leaderboard_period(
     'legendary', current_date - 1, current_date - 1, 43, 0
   )),
  'period zero limit clamps to 1'
);

select pg_temp.assert_true(
  (select count(*) = 100
   from friends_leaderboard(
     current_date - 1, 'legendary', 43, 1000000
   )),
  'friends daily huge limit clamps to 100'
);
select pg_temp.assert_true(
  (select count(*) = 1
   from friends_leaderboard_period(
     'legendary', current_date - 1, current_date - 1, 43, -1
   )),
  'friends period negative limit clamps to 1'
);

select pg_temp.assert_true(
  (select count(*) = 3
   from friends_leaderboard(current_date - 1, 'easy', 42, 100)),
  'friends board contains self and both friendship directions only'
);
select pg_temp.assert_true(
  not exists (
    select 1
    from friends_leaderboard(current_date - 1, 'easy', 42, 100)
    where display_name = 'Smoke Stranger'
  ),
  'friends board excludes non-friends'
);
select pg_temp.assert_true(
  (select count(*) = 1
   from friends_leaderboard(current_date - 1, 'easy', 41, 100)),
  'friends board respects season filtering'
);

select pg_temp.assert_raises(
  format('select * from my_daily_ranks(%L, %L, 42)', current_date, current_date - 1),
  'daily reversed range'
);
select pg_temp.assert_raises(
  format('select * from my_daily_ranks(%L, %L, 42)', current_date - 1, current_date + 1),
  'daily future range'
);
select pg_temp.assert_raises(
  format('select * from my_daily_ranks(%L, %L, 42)', current_date - 8, current_date - 1),
  'daily span over seven days'
);
select pg_temp.assert_raises(
  format('select * from my_period_ranks(%L, %L, 42)', current_date, current_date - 1),
  'period reversed range'
);
select pg_temp.assert_raises(
  format('select * from my_period_ranks(%L, %L, 42)', current_date - 1, current_date + 1),
  'period future range'
);
select pg_temp.assert_raises(
  format('select * from my_period_ranks(%L, %L, 42)', current_date - 32, current_date - 1),
  'period span over 31 days'
);

reset role;

set local role service_role;

select pg_temp.assert_true(
  (select score = 100 and highest_tier = 4
   from public.upsert_best_score(
     '00000000-0000-0000-0000-000000000005',
     current_date,
     'easy',
     44,
     100,
     4
   )),
  'upsert_best_score inserts the first season-scoped score'
);
select pg_temp.assert_true(
  (select score = 100 and highest_tier = 4
   from public.upsert_best_score(
     '00000000-0000-0000-0000-000000000005',
     current_date,
     'easy',
     44,
     50,
     9
   )),
  'upsert_best_score cannot replace the best score or its tier with a lower run'
);
select pg_temp.assert_true(
  (select score = 150 and highest_tier = 7
   from public.upsert_best_score(
     '00000000-0000-0000-0000-000000000005',
     current_date,
     'easy',
     44,
     150,
     7
   )),
  'upsert_best_score atomically replaces both fields for a higher run'
);
select pg_temp.assert_true(
  exists (
    select 1 from public.scores
    where player_id = '00000000-0000-0000-0000-000000000005'
      and utc_date = current_date
      and difficulty = 'easy'
      and season = 44
      and score = 150
      and highest_tier = 7
  ),
  'upsert_best_score persists the requested season'
);

reset role;

select pg_temp.assert_true(
  has_function_privilege(
    'service_role',
    'public.upsert_best_score(uuid,date,text,integer,integer,integer)',
    'EXECUTE'
  ),
  'service_role can execute upsert_best_score'
);
select pg_temp.assert_true(
  not has_function_privilege(
    'anon',
    'public.upsert_best_score(uuid,date,text,integer,integer,integer)',
    'EXECUTE'
  ) and not has_function_privilege(
    'authenticated',
    'public.upsert_best_score(uuid,date,text,integer,integer,integer)',
    'EXECUTE'
  ),
  'anon and authenticated cannot execute upsert_best_score'
);
select pg_temp.assert_true(
  not exists (
    select 1
    from pg_proc as p
    cross join lateral aclexplode(
      coalesce(p.proacl, acldefault('f', p.proowner))
    ) as acl
    where p.oid =
      'public.upsert_best_score(uuid,date,text,integer,integer,integer)'::regprocedure
      and acl.grantee = 0
      and acl.privilege_type = 'EXECUTE'
  ),
  'PUBLIC cannot execute upsert_best_score'
);
select pg_temp.assert_true(
  (select not p.prosecdef and 'search_path=public' = any(p.proconfig)
   from pg_proc as p
   where p.oid =
     'public.upsert_best_score(uuid,date,text,integer,integer,integer)'::regprocedure),
  'upsert_best_score is SECURITY INVOKER with a pinned public search_path'
);
select pg_temp.assert_true(
  (select count(*) = 1
   from pg_constraint
   where conrelid = 'public.scores'::regclass
     and contype = 'u'
     and pg_get_constraintdef(oid) =
       'UNIQUE (player_id, utc_date, difficulty)'),
  'Phase 1 preserves the old conflict target for the deployed Edge Function'
);
select pg_temp.assert_true(
  (select count(*) = 1
   from pg_constraint
   where conrelid = 'public.scores'::regclass
     and contype = 'u'
     and pg_get_constraintdef(oid) =
       'UNIQUE (player_id, utc_date, difficulty, season)'),
  'Phase 1 adds the season-scoped conflict target'
);

select pg_temp.assert_true(
  not has_function_privilege(
    'anon',
    'public.friends_leaderboard(date,text,integer,integer)',
    'EXECUTE'
  ),
  'anon cannot execute friends_leaderboard'
);
select pg_temp.assert_true(
  not has_function_privilege(
    'anon',
    'public.friends_leaderboard_period(text,date,date,integer,integer)',
    'EXECUTE'
  ),
  'anon cannot execute friends_leaderboard_period'
);
select pg_temp.assert_true(
  not has_function_privilege(
    'anon',
    'public.my_daily_ranks(date,date,integer)',
    'EXECUTE'
  ),
  'anon cannot execute my_daily_ranks'
);
select pg_temp.assert_true(
  not has_function_privilege(
    'anon',
    'public.my_period_ranks(date,date,integer)',
    'EXECUTE'
  ),
  'anon cannot execute my_period_ranks'
);

-- Diagnostics only: tiny fixtures may legitimately choose sequential scans.
explain
select *
from scores
where season = 42
  and utc_date between current_date - 7 and current_date - 1
  and difficulty = 'easy'
order by score desc;

explain
select *
from friendships
where '00000000-0000-0000-0000-000000000005'::uuid in (a, b);

rollback;

\echo 'leaderboard smoke checks passed'
