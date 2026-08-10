-- Sum-based uncapped merges can push a daily score beyond int4. Recreate every
-- score-returning RPC from its latest definition while preserving its exact
-- security, search_path, and grant contract.

drop function if exists public.upsert_best_score(uuid, date, text, int, int, int);
drop function if exists public.leaderboard(date, text, int, int);
drop function if exists public.leaderboard_period(text, date, date, int, int);
drop function if exists public.friends_leaderboard(date, text, int, int);
drop function if exists public.friends_leaderboard_period(text, date, date, int, int);

alter table public.scores
  alter column score type bigint using score::bigint;

create function public.upsert_best_score(
  p_player_id uuid,
  p_utc_date date,
  p_difficulty text,
  p_season int,
  p_score bigint,
  p_highest_tier int
)
returns table(score bigint, highest_tier int)
language sql volatile security invoker
set search_path = public
as $$
  insert into scores (
    player_id,
    utc_date,
    difficulty,
    season,
    score,
    highest_tier
  ) values (
    p_player_id,
    p_utc_date,
    p_difficulty,
    p_season,
    p_score,
    p_highest_tier
  )
  on conflict (player_id, utc_date, difficulty, season) do update
  set score = greatest(scores.score, excluded.score),
      highest_tier = case
        when excluded.score > scores.score then excluded.highest_tier
        else scores.highest_tier
      end
  returning scores.score, scores.highest_tier;
$$;

revoke all on function public.upsert_best_score(uuid, date, text, int, bigint, int)
  from public, anon, authenticated;
grant execute on function public.upsert_best_score(uuid, date, text, int, bigint, int)
  to service_role;

create function public.leaderboard(
  p_date date,
  p_diff text,
  p_season int,
  p_limit int default 100
)
returns table(rank bigint, display_name text, score bigint, is_me boolean)
language sql stable security definer
set search_path = public
as $$
  select rank() over (order by s.score desc) as rank,
         p.display_name,
         s.score,
         coalesce(s.player_id = auth.uid(), false) as is_me
  from scores s
  join players p on p.id = s.player_id
  where s.utc_date = p_date
    and s.difficulty = p_diff
    and s.season = p_season
  order by s.score desc
  limit least(greatest(coalesce(p_limit, 100), 1), 100);
$$;

revoke execute on function public.leaderboard(date, text, int, int)
  from public, anon;
grant execute on function public.leaderboard(date, text, int, int)
  to anon, authenticated;

create function public.leaderboard_period(
  p_diff text,
  p_from date,
  p_to date,
  p_season int,
  p_limit int default 100
)
returns table(rank bigint, display_name text, total bigint, is_me boolean)
language sql stable security definer
set search_path = public
as $$
  select rank() over (order by sum(s.score) desc) as rank,
         p.display_name,
         sum(s.score)::bigint as total,
         coalesce(bool_or(s.player_id = auth.uid()), false) as is_me
  from scores s
  join players p on p.id = s.player_id
  where s.difficulty = p_diff
    and s.utc_date between p_from and p_to
    and s.season = p_season
  group by p.id, p.display_name
  order by total desc
  limit least(greatest(coalesce(p_limit, 100), 1), 100);
$$;

revoke execute on function public.leaderboard_period(text, date, date, int, int)
  from public, anon;
grant execute on function public.leaderboard_period(text, date, date, int, int)
  to anon, authenticated;

create function public.friends_leaderboard(
  p_date date,
  p_diff text,
  p_season int,
  p_limit int default 100
)
returns table(
  rank bigint,
  display_name text,
  score bigint,
  is_me boolean,
  player_id uuid
)
language sql stable security definer
set search_path = public
as $$
  with friends as (
    select case when a = auth.uid() then b else a end as fid
    from friendships
    where auth.uid() in (a, b)
    union
    select auth.uid()
  )
  select rank() over (order by s.score desc) as rank,
         p.display_name,
         s.score,
         coalesce(s.player_id = auth.uid(), false) as is_me,
         s.player_id
  from scores s
  join players p on p.id = s.player_id
  where s.utc_date = p_date
    and s.difficulty = p_diff
    and s.season = p_season
    and s.player_id in (select fid from friends)
  order by s.score desc
  limit least(greatest(coalesce(p_limit, 100), 1), 100);
$$;

revoke execute on function public.friends_leaderboard(date, text, int, int)
  from public, anon;
grant execute on function public.friends_leaderboard(date, text, int, int)
  to authenticated;

create function public.friends_leaderboard_period(
  p_diff text,
  p_from date,
  p_to date,
  p_season int,
  p_limit int default 100
)
returns table(rank bigint, display_name text, total bigint, is_me boolean)
language sql stable security definer
set search_path = public
as $$
  with friends as (
    select case when a = auth.uid() then b else a end as fid
    from friendships
    where auth.uid() in (a, b)
    union
    select auth.uid()
  )
  select rank() over (order by sum(s.score) desc) as rank,
         p.display_name,
         sum(s.score)::bigint as total,
         coalesce(bool_or(s.player_id = auth.uid()), false) as is_me
  from scores s
  join players p on p.id = s.player_id
  where s.difficulty = p_diff
    and s.utc_date between p_from and p_to
    and s.season = p_season
    and s.player_id in (select fid from friends)
  group by p.id, p.display_name
  order by total desc
  limit least(greatest(coalesce(p_limit, 100), 1), 100);
$$;

revoke execute on function public.friends_leaderboard_period(text, date, date, int, int)
  from public, anon;
grant execute on function public.friends_leaderboard_period(text, date, date, int, int)
  to authenticated;
