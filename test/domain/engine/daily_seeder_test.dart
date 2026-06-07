import 'package:flutter_test/flutter_test.dart';
import 'package:merge_loop/domain/constants.dart';
import 'package:merge_loop/domain/engine/daily_seeder.dart';
import 'package:merge_loop/domain/models/difficulty.dart';

void main() {
  test('same date+tier yields identical initial board and drop tiers', () {
    final a = const DailySeeder('2026-06-06', Difficulty.medium).generate();
    final b = const DailySeeder('2026-06-06', Difficulty.medium).generate();
    expect(a.board.toJson(), b.board.toJson());
    expect(a.dropTiers, b.dropTiers);
  });

  test('different dates differ (same tier)', () {
    final a = const DailySeeder('2026-06-06', Difficulty.medium).generate();
    final b = const DailySeeder('2026-06-07', Difficulty.medium).generate();
    expect(a.board.toJson(), isNot(b.board.toJson()));
  });

  test('different tiers on same date produce different boards', () {
    final easy = const DailySeeder('2026-06-06', Difficulty.easy).generate();
    final hard = const DailySeeder('2026-06-06', Difficulty.hard).generate();
    expect(easy.board.toJson(), isNot(hard.board.toJson()));
    // Drop schedules also differ because the seed key differs.
    expect(easy.dropTiers, isNot(hard.dropTiers));
  });

  test('each tier places exactly its startingFill tiles, all tier 1-2', () {
    for (final d in Difficulty.values) {
      final start = DailySeeder('2026-06-06', d).generate();
      expect(start.board.filledCount, d.startingFill,
          reason: '${d.name} should place ${d.startingFill} tiles');
      for (final c in start.board.cells) {
        if (c != null) expect(c.tier, inInclusiveRange(1, 2));
      }
    }
  });

  test('tile counts are 10/8/6/4 for easy/medium/hard/legendary', () {
    expect(const DailySeeder('2026-06-06', Difficulty.easy)
        .generate()
        .board
        .filledCount, 10);
    expect(const DailySeeder('2026-06-06', Difficulty.medium)
        .generate()
        .board
        .filledCount, 8);
    expect(const DailySeeder('2026-06-06', Difficulty.hard)
        .generate()
        .board
        .filledCount, 6);
    expect(const DailySeeder('2026-06-06', Difficulty.legendary)
        .generate()
        .board
        .filledCount, 4);
  });

  test('drop schedule has kMaxDrops tiers, each within its band', () {
    final start =
        const DailySeeder('2026-06-06', Difficulty.medium).generate();
    expect(start.dropTiers.length, kMaxDrops);
    for (var n = 0; n < start.dropTiers.length; n++) {
      expect(start.dropTiers[n], inInclusiveRange(1, dropCap(n)));
    }
  });

  test('landingPrng is independent of dropTier draws and reproducible', () {
    const s = DailySeeder('2026-06-06', Difficulty.medium);
    final p1 = s.landingPrng();
    final p2 = s.landingPrng();
    expect(List.generate(10, (_) => p1.nextU32()),
        List.generate(10, (_) => p2.nextU32()));
  });

  test('seedForKey is deterministic and key-sensitive', () {
    expect(DailySeeder.seedForKey('2026-06-06:hard'),
        DailySeeder.seedForKey('2026-06-06:hard'));
    expect(DailySeeder.seedForKey('2026-06-06:hard'),
        isNot(DailySeeder.seedForKey('2026-06-06:easy')));
  });
}
