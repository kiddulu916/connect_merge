-- Connect-Merge relaunch: leaderboard hard reset via a season tag.
--
-- The redesigned mechanic produces a different score distribution, so old
-- (season 1) scores are not comparable. Rather than delete history, we tag every
-- score with a season and filter all reads to the current season. Pre-relaunch
-- rows default to season 1 and therefore never appear once the client + Edge
-- Function submit/read season 2 (= kLeaderboardSeason).
--
-- Trust model unchanged: clients still cannot write `scores`; only the
-- submit-score Edge Function (service role) writes, and it stamps the season
-- from its OWN constant (never from the client payload).

-- 1. Schema: add the season column. Existing rows become season 1.
alter table scores add column if not exists season int not null default 1;

-- Season-aware covering index for the (season, date, difficulty) range scans the
-- read RPCs now perform.
create index if not exists idx_scores_board_season
  on scores (season, utc_date, difficulty, score desc);

-- 2. Recreate the three read RPCs with a p_season filter. A new parameter
--    changes the function signature, so the old signatures must be DROPPED first
--    (CREATE OR REPLACE alone would leave the old overloads callable, which would
--    keep leaking season-1 rows to any caller using the old arg list).

-- leaderboard(p_date, p_diff, p_limit) -> add p_season (before the defaulted arg
-- so no default is required on p_season). Callers pass named params.
drop function if exists leaderboard(date, text, int);
create or replace function leaderboard(
  p_date date,
  p_diff text,
  p_season int,
  p_limit int default 100
)
returns table(rank bigint, display_name text, score int, is_me boolean)
language sql stable security invoker
set search_path = public
as $$
  select rank() over (order by s.score desc) as rank,
         p.display_name, s.score, (s.player_id = auth.uid()) as is_me
  from scores s join players p on p.id = s.player_id
  where s.utc_date = p_date and s.difficulty = p_diff and s.season = p_season
  order by s.score desc limit p_limit;
$$;
grant execute on function leaderboard(date, text, int, int) to anon, authenticated;

-- friends_leaderboard(p_date, p_diff) -> add p_season.
drop function if exists friends_leaderboard(date, text);
create or replace function friends_leaderboard(
  p_date date,
  p_diff text,
  p_season int
)
returns table(rank bigint, display_name text, score int, is_me boolean)
language sql stable security invoker
set search_path = public
as $$
  with friends as (
    select case when a = auth.uid() then b else a end as fid
    from friendships where auth.uid() in (a, b)
    union
    select auth.uid()
  )
  select rank() over (order by s.score desc) as rank,
         p.display_name, s.score, (s.player_id = auth.uid()) as is_me
  from scores s join players p on p.id = s.player_id
  where s.utc_date = p_date and s.difficulty = p_diff and s.season = p_season
    and s.player_id in (select fid from friends)
  order by s.score desc;
$$;
grant execute on function friends_leaderboard(date, text, int) to authenticated;

-- leaderboard_period(p_diff, p_from, p_to) -> add p_season.
drop function if exists leaderboard_period(text, date, date);
create or replace function leaderboard_period(
  p_diff text,
  p_from date,
  p_to date,
  p_season int
)
returns table(rank bigint, display_name text, total int, is_me boolean)
language sql stable security invoker
set search_path = public
as $$
  select rank() over (order by sum(s.score) desc) as rank,
         p.display_name,
         sum(s.score)::int as total,
         bool_or(s.player_id = auth.uid()) as is_me
  from scores s
  join players p on p.id = s.player_id
  where s.difficulty = p_diff
    and s.utc_date between p_from and p_to
    and s.season = p_season
  group by p.id, p.display_name
  order by total desc;
$$;
grant execute on function leaderboard_period(text, date, date, int) to anon, authenticated;
