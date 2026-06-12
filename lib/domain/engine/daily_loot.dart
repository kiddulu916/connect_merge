import '../constants.dart';
import '../models/loot_reward.dart';
import 'daily_seeder.dart';
import 'prng.dart';

/// Derives the day's Daily Loot Chest reward deterministically from the daily
/// seed (`"$date:loot"`), mirroring [DailySeeder]'s seed-derivation design.
///
/// Because the variance comes from the seed — never `Random()` — the reward is
/// byte-identical for every player on a given UTC date, cheat-proof, and free.
/// Bands are weighted so small rewards are common and jackpots rare (the
/// variable-reward dopamine core).
class DailyLoot {
  const DailyLoot._();

  /// The reward for [date] (UTC `YYYY-MM-DD`). Pure and deterministic.
  static LootReward forDate(String date) {
    final p = Prng(DailySeeder.seedForKey('$date:loot'));
    final roll = p.nextInt(100);
    final int coins;
    if (roll < kLootCommonRollMax) {
      coins = kLootCommonBase + p.nextInt(kLootCommonSpan); // common
    } else if (roll < kLootUncommonRollMax) {
      coins = kLootUncommonBase + p.nextInt(kLootUncommonSpan); // uncommon
    } else {
      coins = kLootJackpotBase + p.nextInt(kLootJackpotSpan); // rare jackpot
    }
    final shard = roll >= kLootShardThreshold ? _shardFor(p) : null;
    return LootReward(coins: coins, shardCosmetic: shard, doubled: false);
  }

  /// A deterministic cosmetic-shard token for a rare drop. Stable storage token
  /// (never localized); kept generic so later phases can map it to a cosmetic.
  static String _shardFor(Prng p) {
    const shards = ['ocean', 'sunset', 'forest', 'aurora'];
    return 'shard_${shards[p.nextInt(shards.length)]}';
  }
}
