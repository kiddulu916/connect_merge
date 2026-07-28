import { assertEquals } from "jsr:@std/assert@1";
import {
  type BoardState,
  type ChallengeRule,
  type Difficulty,
  kMaxDrops,
  minChainLengthFor,
} from "./constants.ts";
import { challengeRule, DailySeeder } from "./seeder.ts";
import { seedChallengeStart } from "./engine.ts";
import fixture from "./board_vectors.json" with { type: "json" };

interface Entry {
  date: string;
  difficulty: string;
  digest: string;
}

const entries = fixture.entries as Entry[];

async function dropSchedule(seeder: DailySeeder): Promise<number[]> {
  const p = await seeder.dropTierPrng();
  const out: number[] = [];
  for (let n = 0; n < kMaxDrops; n++) out.push(seeder.dropTierAt(p, n));
  return out;
}

function canonical(
  board: BoardState,
  drops: number[],
  rule: string,
  mcl: number,
): string {
  const cells = board.cells
    .map((t) => (t === null ? "x" : `${t.tier}`))
    .join(",");
  const walls = [...board.walls].sort((a, b) => a - b).join(",");
  return `g=${board.gridSize};m=${board.movesRemaining};cells=${cells};` +
    `walls=${walls};drops=${drops.join(",")};rule=${rule};mcl=${mcl}`;
}

async function digest(canonicalStr: string): Promise<string> {
  const bytes = new TextEncoder().encode(canonicalStr);
  const buf = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(buf)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function digestFor(date: string, difficulty: string): Promise<string> {
  const seeder = new DailySeeder(date, difficulty as Difficulty);
  let board: BoardState;
  let rule: string;
  let mcl: number;
  if (difficulty === "challenge") {
    const seed = await seedChallengeStart(date);
    board = seed.start.board;
    const r: ChallengeRule = await challengeRule(date);
    rule = r;
    mcl = minChainLengthFor(r);
  } else {
    board = (await seeder.generate()).board;
    rule = "-";
    mcl = 2;
  }
  return await digest(canonical(board, await dropSchedule(seeder), rule, mcl));
}

Deno.test("board_vectors: TS board generation matches the committed digests", async () => {
  assertEquals(entries.length, (fixture.days as number) * 5);
  for (const entry of entries) {
    const actual = await digestFor(entry.date, entry.difficulty);
    assertEquals(
      actual,
      entry.digest,
      `board digest drift at ${entry.date} ${entry.difficulty}`,
    );
  }
});
