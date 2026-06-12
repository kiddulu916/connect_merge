import 'package:flutter_test/flutter_test.dart';
import 'package:merge_count/domain/constants.dart';
import 'package:merge_count/domain/engine/daily_loot.dart';

void main() {
  group('DailyLoot.forDate', () {
    test('is byte-identical across many calls for the same date', () {
      final first = DailyLoot.forDate('2026-06-11');
      for (var i = 0; i < 1000; i++) {
        expect(DailyLoot.forDate('2026-06-11'), first);
      }
    });

    test('different dates generally differ', () {
      // Not a hard guarantee for any single pair, but over a span the rewards
      // must vary (otherwise the seed is being ignored).
      final coins = <int>{};
      for (var d = 1; d <= 28; d++) {
        coins.add(
            DailyLoot.forDate('2026-06-${d.toString().padLeft(2, '0')}').coins);
      }
      expect(coins.length, greaterThan(1));
    });

    test('every reward falls within a valid band', () {
      const maxCoins = kLootJackpotBase + kLootJackpotSpan;
      for (var d = 1; d <= 28; d++) {
        final r = DailyLoot.forDate('2026-07-${d.toString().padLeft(2, '0')}');
        expect(r.coins, inInclusiveRange(kLootCommonBase, maxCoins));
        expect(r.doubled, isFalse);
      }
    });

    test('bands appear at roughly their configured frequencies', () {
      var common = 0, uncommon = 0, jackpot = 0;
      const days = 2000;
      final start = DateTime.utc(2026, 1, 1);
      for (var i = 0; i < days; i++) {
        final date = start.add(Duration(days: i));
        final key =
            '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
        final coins = DailyLoot.forDate(key).coins;
        if (coins < kLootUncommonBase) {
          common++;
        } else if (coins < kLootJackpotBase) {
          uncommon++;
        } else {
          jackpot++;
        }
      }
      // Common is the dominant band; jackpots are rare.
      expect(common, greaterThan(uncommon));
      expect(common, greaterThan(jackpot));
      expect(jackpot / days, lessThan(0.12)); // rare
      expect(jackpot, greaterThan(0)); // but present over a large sample
    });

    test('cosmetic shards are rare and only on high rolls', () {
      var withShard = 0;
      const days = 2000;
      final start = DateTime.utc(2026, 1, 1);
      for (var i = 0; i < days; i++) {
        final date = start.add(Duration(days: i));
        final key =
            '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
        final r = DailyLoot.forDate(key);
        if (r.shardCosmetic != null) {
          withShard++;
          // Shards only ever drop in the jackpot band.
          expect(r.coins, greaterThanOrEqualTo(kLootJackpotBase));
        }
      }
      expect(withShard / days, lessThan(0.06));
    });

    test('asDoubled doubles coins and flags doubled, preserving the shard', () {
      final r = DailyLoot.forDate('2026-06-11');
      final d = r.asDoubled();
      expect(d.coins, r.coins * 2);
      expect(d.doubled, isTrue);
      expect(d.shardCosmetic, r.shardCosmetic);
    });
  });
}
