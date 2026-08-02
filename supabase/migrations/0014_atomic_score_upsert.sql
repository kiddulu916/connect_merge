-- Phase 1 of the score-upsert rollout: add the season-aware conflict target
-- alongside the old target, then expose one service-role-only atomic writer.
-- The old constraint stays until the updated Edge Function is deployed and
-- verified, so the currently deployed select+upsert path remains valid.

alter table public.scores
  add constraint scores_player_date_difficulty_season_key
  unique (player_id, utc_date, difficulty, season);

create function public.upsert_best_score(
  p_player_id uuid,
  p_utc_date date,
  p_difficulty text,
  p_season int,
  p_score int,
  p_highest_tier int
)
returns table(score int, highest_tier int)
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

revoke all on function public.upsert_best_score(uuid, date, text, int, int, int)
  from public, anon, authenticated;
grant execute on function public.upsert_best_score(uuid, date, text, int, int, int)
  to service_role;
