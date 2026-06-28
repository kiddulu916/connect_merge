import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/models/achievement.dart';
import 'package:connect_merge/domain/models/cosmetic.dart';
import 'package:connect_merge/presentation/theme/tile_palette.dart';
import 'package:connect_merge/presentation/widgets/grid_cell_widget.dart';
import 'package:connect_merge/domain/models/tile.dart';

void main() {
  group('TilePalette cosmetics', () {
    test('classic is the backward-compatible default', () {
      expect(TilePalette.colorForTier(1), TilePalette.colorFor(Cosmetic.classic, 1));
    });

    test('different cosmetics produce different tier colors', () {
      // Ocean tier 1 differs from classic tier 1.
      expect(TilePalette.colorFor(Cosmetic.ocean, 1),
          isNot(equals(TilePalette.colorFor(Cosmetic.classic, 1))));
    });

    test('tier index clamps to the palette range', () {
      // tier 99 clamps to the last ramp entry.
      expect(TilePalette.colorFor(Cosmetic.classic, 99),
          TilePalette.colorFor(Cosmetic.classic, 11));
    });
  });

  group('Cosmetic unlock predicates (pure)', () {
    test('free is always unlocked; streak/achievement/ad gated', () {
      expect(
          Cosmetic.classic.isUnlocked(
              dailyActiveStreak: 0, achievements: {}, adUnlocked: {}),
          isTrue);
      // ocean unlocks at 3-day streak.
      expect(
          Cosmetic.ocean.isUnlocked(
              dailyActiveStreak: 2, achievements: {}, adUnlocked: {}),
          isFalse);
      expect(
          Cosmetic.ocean.isUnlocked(
              dailyActiveStreak: 3, achievements: {}, adUnlocked: {}),
          isTrue);
      // regal needs the legendary-clear achievement.
      expect(
          Cosmetic.regal.isUnlocked(
              dailyActiveStreak: 100, achievements: {}, adUnlocked: {}),
          isFalse);
      expect(
          Cosmetic.regal.isUnlocked(
              dailyActiveStreak: 0,
              achievements: {Achievement.firstLegendaryClear},
              adUnlocked: {}),
          isTrue);
      // neon only via explicit ad unlock.
      expect(
          Cosmetic.neon.isUnlocked(
              dailyActiveStreak: 100,
              achievements: Achievement.values.toSet(),
              adUnlocked: {}),
          isFalse);
      expect(
          Cosmetic.neon.isUnlocked(
              dailyActiveStreak: 0,
              achievements: {},
              adUnlocked: {Cosmetic.neon}),
          isTrue);
    });
  });

  testWidgets('GridCellWidget renders the selected cosmetic color',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: GridCellWidget(
        tile: Tile(id: 0, tier: 1),
        size: 40,
        cosmetic: Cosmetic.ocean,
      ),
    ));
    final container = tester.widget<Container>(
        find.descendant(of: find.byType(GridCellWidget), matching: find.byType(Container)).first);
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.color, TilePalette.colorFor(Cosmetic.ocean, 1));
  });
}
