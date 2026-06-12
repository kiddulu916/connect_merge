import 'package:flutter_test/flutter_test.dart';
import 'package:merge_count/domain/constants.dart';
import 'package:merge_count/domain/models/player_level.dart';

void main() {
  group('xpForScore', () {
    test('floors score by kXpPerScore; non-positive scores yield 0', () {
      expect(xpForScore(0), 0);
      expect(xpForScore(-100), 0);
      expect(xpForScore(kXpPerScore - 1), 0);
      expect(xpForScore(kXpPerScore), 1);
      expect(xpForScore(kXpPerScore * 3 + 5), 3);
    });
  });

  group('levelForXp', () {
    test('0 / negative xp -> level 0', () {
      expect(levelForXp(0), 0);
      expect(levelForXp(-1), 0);
    });

    test('matches floor(sqrt(xp / base)) at thresholds', () {
      // level 1 starts at 1^2 * base, level 2 at 2^2 * base, etc.
      expect(levelForXp(xpForLevel(1) - 1), 0);
      expect(levelForXp(xpForLevel(1)), 1);
      expect(levelForXp(xpForLevel(2) - 1), 1);
      expect(levelForXp(xpForLevel(2)), 2);
      expect(levelForXp(xpForLevel(5)), 5);
    });
  });

  group('xpForLevel is the inverse threshold', () {
    test('round-trips with levelForXp at each boundary', () {
      for (var lvl = 0; lvl <= 20; lvl++) {
        expect(levelForXp(xpForLevel(lvl)), lvl,
            reason: 'level $lvl boundary should map back to $lvl');
      }
    });
  });

  group('monotonicity (FAILURE MODE: non-monotonic curve)', () {
    test('level never decreases as xp increases across a wide range', () {
      var prev = 0;
      for (var xp = 0; xp <= 100000; xp += 7) {
        final lvl = levelForXp(xp);
        expect(lvl, greaterThanOrEqualTo(prev),
            reason: 'level dropped at xp=$xp');
        prev = lvl;
      }
    });
  });

  group('xpForNextLevel', () {
    test('always strictly positive', () {
      for (var xp = 0; xp <= 5000; xp += 13) {
        expect(xpForNextLevel(xp), greaterThan(0));
      }
    });

    test('at an exact level boundary, equals the gap to the next boundary', () {
      final atLevel2 = xpForLevel(2);
      expect(xpForNextLevel(atLevel2), xpForLevel(3) - atLevel2);
    });
  });

  group('levelProgress', () {
    test('0 at a fresh level boundary, ~1 just before the next', () {
      final atLevel3 = xpForLevel(3);
      expect(levelProgress(atLevel3), 0);
      expect(levelProgress(xpForLevel(4) - 1), greaterThan(0.9));
    });

    test('stays within [0, 1]', () {
      for (var xp = 0; xp <= 5000; xp += 11) {
        final p = levelProgress(xp);
        expect(p, inInclusiveRange(0.0, 1.0));
      }
    });
  });
}
