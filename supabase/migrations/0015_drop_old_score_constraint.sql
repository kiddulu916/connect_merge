-- Phase 3 of the score-upsert rollout (0014): the season-aware conflict
-- target and upsert_best_score have been live on submit-score since its
-- redeploy, verified via a real RPC call against production data. The old
-- season-less constraint is no longer referenced by any deployed code path,
-- so it's safe to drop — it was also the source of the latent season-mixing
-- bug 0014's migration comment flagged (a season bump without a full wipe
-- could silently merge a prior season's row under the old 3-column target).

alter table public.scores
  drop constraint scores_player_id_utc_date_difficulty_key;
