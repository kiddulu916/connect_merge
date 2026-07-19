-- Leaderboard read repair and bounded prize-rank seams.
--
-- `players` remains self-only under RLS. Display boards need cross-player names,
-- so they are tightly projected SECURITY DEFINER functions that expose only
-- rank, display name, score/total, and the caller flag. Prize rank functions do
-- not join `players`; they stay SECURITY INVOKER over world-readable `scores`.

create index if not exists idx_friendships_b on friendships (b);

-- 0001 declared scores world-readable (RLS policy `scores_read using (true)`),
-- but stacks provisioned without DML default privileges leave `authenticated`
-- with no table-level SELECT, which breaks the SECURITY INVOKER my_* functions
-- below with "permission denied for table scores". Grant it explicitly; the
-- RLS policy remains the row-visibility authority.
grant select on table public.scores to authenticated;

-- Signature changes and return-type changes require dropping the old overloads.
drop function if exists public.leaderboard(date, text, int, int);
drop function if exists public.leaderboard_period(text, date, date, int);
drop function if exists public.leaderboard_period(text, date, date, int, int);
drop function if exists public.friends_leaderboard(date, text, int);
drop function if exists public.friends_leaderboard(date, text, int, int);
drop function if exists public.friends_leaderboard_period(text, date, date, int, int);
drop function if exists public.my_daily_ranks(date, date, int);
drop function if exists public.my_period_ranks(date, date, int);

create function public.leaderboard(
  p_date date,
  p_diff text,
  p_season int,
  p_limit int default 100
)
returns table(rank bigint, display_name text, score int, is_me boolean)
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
         sum(s.score) as total,
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
returns table(rank bigint, display_name text, score int, is_me boolean)
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
         coalesce(s.player_id = auth.uid(), false) as is_me
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
         sum(s.score) as total,
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

create function public.my_daily_ranks(
  p_from date,
  p_to date,
  p_season int
)
returns table(utc_date date, difficulty text, rank bigint)
language plpgsql stable security invoker
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'unauthenticated';
  end if;
  if p_from is null or p_to is null then
    raise exception 'range dates are required';
  end if;
  if p_from > p_to then
    raise exception 'reversed range';
  end if;
  if p_to > current_date then
    raise exception 'future range';
  end if;
  if p_to - p_from > 6 then
    raise exception 'daily rank range exceeds 7 days';
  end if;

  return query
  select ranked.utc_date, ranked.difficulty, ranked.player_rank
  from (
    select s.utc_date,
           s.difficulty,
           s.player_id,
           rank() over (
             partition by s.utc_date, s.difficulty
             order by s.score desc
           ) as player_rank
    from scores s
    where s.utc_date between p_from and p_to
      and s.season = p_season
  ) ranked
  where ranked.player_id = auth.uid()
  order by ranked.utc_date, ranked.difficulty;
end;
$$;

revoke execute on function public.my_daily_ranks(date, date, int)
  from public, anon;
grant execute on function public.my_daily_ranks(date, date, int)
  to authenticated;

create function public.my_period_ranks(
  p_from date,
  p_to date,
  p_season int
)
returns table(difficulty text, rank bigint)
language plpgsql stable security invoker
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'unauthenticated';
  end if;
  if p_from is null or p_to is null then
    raise exception 'range dates are required';
  end if;
  if p_from > p_to then
    raise exception 'reversed range';
  end if;
  if p_to > current_date then
    raise exception 'future range';
  end if;
  if p_to - p_from > 30 then
    raise exception 'period rank range exceeds 31 days';
  end if;

  return query
  select ranked.difficulty, ranked.player_rank
  from (
    select totals.difficulty,
           totals.player_id,
           rank() over (
             partition by totals.difficulty
             order by totals.total desc
           ) as player_rank
    from (
      select s.difficulty, s.player_id, sum(s.score) as total
      from scores s
      where s.utc_date between p_from and p_to
        and s.season = p_season
      group by s.difficulty, s.player_id
    ) totals
  ) ranked
  where ranked.player_id = auth.uid()
  order by ranked.difficulty;
end;
$$;

revoke execute on function public.my_period_ranks(date, date, int)
  from public, anon;
grant execute on function public.my_period_ranks(date, date, int)
  to authenticated;
