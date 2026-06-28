import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/models/difficulty.dart';

void main() {
  test('board geometry is 5x5 = 25 cells', () {
    expect(kGridSize, 5);
    expect(kCellCount, 25);
  });

  test('dropCap starts at 2 and steps up, clamped to 6', () {
    expect(dropCap(0), 2);
    expect(dropCap(5), 2);
    expect(dropCap(6), 3);
    expect(dropCap(30), 7 > 6 ? 6 : 7); // clamped
    expect(dropCap(1000), 6);
  });

  group('Connect-Merge constants', () {
    test('comboMultiplier is 1 at length 2 and grows superlinearly', () {
      expect(comboMultiplier(2), 1);
      expect(comboMultiplier(3), 2);
      expect(comboMultiplier(4), 4);
      expect(comboMultiplier(5), 7);
      expect(comboMultiplier(6), 11);
      // strictly increasing
      for (var n = 3; n <= 12; n++) {
        expect(comboMultiplier(n) > comboMultiplier(n - 1), isTrue);
      }
    });

    test('wall count increases as the board gets harder', () {
      expect(wallCountFor(Difficulty.easy), 2);
      expect(wallCountFor(Difficulty.legendary) >= wallCountFor(Difficulty.easy),
          isTrue);
    });

    test('queue + version knobs have sane values', () {
      expect(kDropQueueVisible, 3);
      expect(kSnapshotVersion >= 2, isTrue);
      expect(kLeaderboardSeason >= 2, isTrue);
    });
  });
}
