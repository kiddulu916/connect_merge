export interface BestScoreInput {
  playerId: string;
  date: string;
  difficulty: string;
  season: number;
  score: number;
  highestTier: number;
}

interface RpcResponse {
  data: unknown;
  error: unknown;
}

type Rpc = (
  functionName: string,
  params: Record<string, unknown>,
) => Promise<RpcResponse>;

export interface BestScore {
  score: number;
  highestTier: number;
}

export async function upsertBestScore(
  rpc: Rpc,
  input: BestScoreInput,
): Promise<BestScore | null> {
  const { data, error } = await rpc("upsert_best_score", {
    p_player_id: input.playerId,
    p_utc_date: input.date,
    p_difficulty: input.difficulty,
    p_season: input.season,
    p_score: input.score,
    p_highest_tier: input.highestTier,
  });
  if (error != null || !Array.isArray(data)) return null;
  const row = data[0];
  if (
    row == null ||
    typeof row !== "object" ||
    typeof (row as Record<string, unknown>).score !== "number" ||
    typeof (row as Record<string, unknown>).highest_tier !== "number"
  ) {
    return null;
  }
  return {
    score: (row as Record<string, number>).score,
    highestTier: (row as Record<string, number>).highest_tier,
  };
}
