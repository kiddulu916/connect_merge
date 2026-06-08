-- Security hardening: pin search_path on the leaderboard read RPCs.
--
-- The Supabase advisor flagged public.leaderboard for a "role mutable search_path"
-- (the function had no `SET search_path`, so name resolution depended on the
-- caller's search_path). The two sibling read functions added later
-- (friends_leaderboard, leaderboard_period) have the same gap, so we fix the whole
-- class here, not just the flagged instance. (redeem_code/ensure_friend_code already
-- pin search_path, set in 0002/0004.)
--
-- These stay SECURITY INVOKER and only read world-readable `scores`; we recreate
-- them verbatim except for the added `set search_path = public`. CREATE OR REPLACE
-- preserves existing EXECUTE grants; we re-affirm them for clarity.

-- leaderboard(p_date, p_diff, p_limit): daily board, top N + caller's is_me flag.
create or replace function leaderboard(p_date date, p_diff text, p_limit int default 100)
returns table(rank bigint, display_name text, score int, is_me boolean)
language sql stable security invoker
set search_path = public
as $$
  select rank() over (order by s.score desc) as rank,
         p.display_name, s.score, (s.player_id = auth.uid()) as is_me
  from scores s join players p on p.id = s.player_id
  where s.utc_date = p_date and s.difficulty = p_diff
  order by s.score desc limit p_limit;
$$;
grant execute on function leaderboard(date, text, int) to anon, authenticated;

-- friends_leaderboard(p_date, p_diff): daily board filtered to caller's friend set.
create or replace function friends_leaderboard(p_date date, p_diff text)
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
  where s.utc_date = p_date and s.difficulty = p_diff
    and s.player_id in (select fid from friends)
  order by s.score desc;
$$;
grant execute on function friends_leaderboard(date, text) to authenticated;

-- leaderboard_period(p_diff, p_from, p_to): weekly/monthly/all-time aggregation
-- (sum of daily bests) over the existing scores rows.
create or replace function leaderboard_period(p_diff text, p_from date, p_to date)
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
  group by p.id, p.display_name
  order by total desc;
$$;
grant execute on function leaderboard_period(text, date, date) to anon, authenticated;
