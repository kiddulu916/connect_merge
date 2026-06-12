import 'package:flutter_test/flutter_test.dart';
import 'package:merge_count/domain/constants.dart';
import 'package:merge_count/domain/engine/almanac_progress.dart';
import 'package:merge_count/domain/models/almanac.dart';

void main() {
  group('Almanac model (pure)', () {
    test('empty almanac discovers/masters nothing', () {
      const a = Almanac.empty;
      expect(a.discoveredCount, 0);
      expect(a.masteredCount, 0);
      expect(a.countFor(9), 0);
      expect(a.isMastered(9), isFalse);
    });

    test('entries cover every live tier even when unreached', () {
      const a = Almanac.empty;
      expect(a.entries.length, kMaxTier); // tiers 1..kMaxTier
      expect(a.entries.first.tier, 1);
      expect(a.entries.last.tier, kMaxTier);
      expect(a.entries.every((e) => e.count == 0), isTrue);
    });

    test('value is 2^tier', () {
      expect(const AlmanacEntry(tier: 9, count: 0).value, 512);
      expect(const AlmanacEntry(tier: 11, count: 0).value, 2048);
    });

    test('mastery flips at the threshold, not before', () {
      const below = Almanac(counts: {9: kAlmanacMasteryThreshold - 1});
      const at = Almanac(counts: {9: kAlmanacMasteryThreshold});
      expect(below.isMastered(9), isFalse);
      expect(at.isMastered(9), isTrue);
      expect(at.masteredCount, 1);
    });

    test('progress is clamped to [0,1]', () {
      const over = AlmanacEntry(tier: 5, count: kAlmanacMasteryThreshold * 3);
      expect(over.progress, 1.0);
      const none = AlmanacEntry(tier: 5, count: 0);
      expect(none.progress, 0.0);
    });
  });

  group('foldRunIntoAlmanac (pure)', () {
    test('increments the reached tier by one', () {
      final c0 = <String, int>{};
      final c1 = foldRunIntoAlmanac(c0, 9);
      expect(c1['9'], 1);
      final c2 = foldRunIntoAlmanac(c1, 9);
      expect(c2['9'], 2);
    });

    test('highestTier <= 0 leaves counts unchanged', () {
      final c0 = {'9': 3};
      expect(foldRunIntoAlmanac(c0, 0), {'9': 3});
      expect(foldRunIntoAlmanac(c0, -1), {'9': 3});
    });

    test('does not mutate the input map', () {
      final c0 = {'9': 1};
      final c1 = foldRunIntoAlmanac(c0, 9);
      expect(c0, {'9': 1}); // original untouched
      expect(c1, {'9': 2});
    });

    test('counts are monotonic: a lower-tier run never lowers a higher count',
        () {
      var counts = <String, int>{};
      counts = foldRunIntoAlmanac(counts, 9); // {9:1}
      counts = foldRunIntoAlmanac(counts, 3); // {9:1, 3:1}
      expect(counts['9'], 1);
      expect(counts['3'], 1);
    });
  });

  group('applyRunToAlmanac + mastery (experiment: tier 9 thrice)', () {
    test('reaching a tier kAlmanacMasteryThreshold times flips its badge', () {
      var a = Almanac.empty;
      for (var i = 0; i < kAlmanacMasteryThreshold - 1; i++) {
        a = applyRunToAlmanac(a, 9);
        expect(a.isMastered(9), isFalse, reason: 'not mastered after ${i + 1}');
      }
      a = applyRunToAlmanac(a, 9);
      expect(a.isMastered(9), isTrue);
      expect(a.countFor(9), kAlmanacMasteryThreshold);
    });
  });

  group('storage round-trip (migration-free)', () {
    test('fromStorage tolerates empty / malformed keys', () {
      expect(Almanac.fromStorage(const {}).counts, isEmpty);
      final a = Almanac.fromStorage({'9': 2, 'bad': 5, '3': 0});
      expect(a.countFor(9), 2);
      expect(a.countFor(3), 0); // zero counts dropped
      expect(a.counts.containsKey(3), isFalse);
    });

    test('toStorage <-> fromStorage round-trips', () {
      const a = Almanac(counts: {9: 2, 11: 1});
      final back = Almanac.fromStorage(a.toStorage());
      expect(back.counts, {9: 2, 11: 1});
    });
  });
}
