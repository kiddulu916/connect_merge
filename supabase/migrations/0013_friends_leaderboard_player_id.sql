-- Expose player_id on the daily friends leaderboard so the client can match a
-- chosen rival's per-tier score back to their id (rivalry "passed you" nudge).
--
-- The row already filters to mutual friends (`s.player_id in (select fid from
-- friends)`) and computes `is_me` from `s.player_id`, so surfacing the id to the
-- caller exposes nothing they aren't already entitled to see. Purely additive:
-- only the daily variant feeds the rivalry wire, so the period board is left
-- untouched. Not a gameplay rule -> no kLeaderboardSeason bump.

-- Return-type change requires dropping the old overload first.
drop function if exists public.friends_leaderboard(date, text, int, int);

create function public.friends_leaderboard(
  p_date date,
  p_diff text,
  p_season int,
  p_limit int default 100
)
returns table(
  rank bigint,
  display_name text,
  score int,
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
