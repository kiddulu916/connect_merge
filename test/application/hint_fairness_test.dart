import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/application/game_cubit.dart';
import 'package:connect_merge/application/game_state.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/engine/daily_seeder.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';

void main() {
  late InMemoryStorageService storage;
  GameCubit make(String date) =>
      GameCubit(storage: storage, todayProvider: () => date);
  setUp(() => storage = InMemoryStorageService());

  group('FAIRNESS INVARIANT #1: hint is read-only on seed-fixed data', () {
    test('peekNextDropTier matches the seeder schedule at the current dropIndex',
        () async {
      const date = '2026-06-07';
      const diff = Difficulty.medium;
      // The seed-fixed drop schedule (the SAME for every player).
      final expectedTiers = const DailySeeder(date, diff).generate().dropTiers;

      final c = make(date);
      await c.init(difficulty: diff);
      // Fresh board: dropIndex 0 -> next drop is dropTiers[0].
      expect(c.peekNextDropTier(), expectedTiers[0]);
    });

    test('using a hint does NOT mutate board state and emits no new state',
        () async {
      const date = '2026-06-07';
      const diff = Difficulty.medium;
      final c = make(date);
      await c.init(difficulty: diff);

      final before = (c.state as GamePlaying).board;
      final stateBefore = c.state;

      final tier = c.revealNextDropAfterReward();
      expect(tier, isNotNull);

      // Board is byte-for-byte unchanged.
      final after = (c.state as GamePlaying).board;
      expect(identical(c.state, stateBefore), isTrue,
          reason: 'hint must not emit a new state');
      expect(after.toJson(), before.toJson());
    });

    test('hint reveal equals what the seed will actually drop next', () async {
      const date = '2026-06-07';
      const diff = Difficulty.hard;
      // The cubit uses dropTierPrng() (the independent ':drops' stream), not
      // generate().dropTiers (stream A tail). Peek at index 0 directly.
      const seeder = DailySeeder(date, diff);
      final expectedTier = seeder.dropTierAt(seeder.dropTierPrng(), 0);

      final c = make(date);
      await c.init(difficulty: diff);
      final revealed = c.revealNextDropAfterReward();
      expect(revealed, expectedTier);
    });

    test('per-day cap: at most kMaxHintsPerDay hints are granted', () async {
      const date = '2026-06-07';
      final c = make(date);
      await c.init(difficulty: Difficulty.medium);

      var granted = 0;
      for (var i = 0; i < kMaxHintsPerDay + 3; i++) {
        if (c.canUseHint && c.revealNextDropAfterReward() != null) granted++;
      }
      expect(granted, kMaxHintsPerDay);
      expect(c.canUseHint, isFalse);
    });
  });
}
