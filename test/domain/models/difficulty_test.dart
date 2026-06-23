import 'package:flutter_test/flutter_test.dart';
import 'package:merge_count/domain/models/difficulty.dart';

void main() {
  test('starting tile counts are 40/25/20/15', () {
    expect(Difficulty.easy.startingFill, 40);
    expect(Difficulty.medium.startingFill, 25);
    expect(Difficulty.hard.startingFill, 20);
    expect(Difficulty.legendary.startingFill, 15);
  });

  test('grid sizes are 8/7/6/6', () {
    expect(Difficulty.easy.gridSize, 8);
    expect(Difficulty.medium.gridSize, 7);
    expect(Difficulty.hard.gridSize, 6);
    expect(Difficulty.legendary.gridSize, 6);
  });

  test('cellCount == gridSize * gridSize', () {
    for (final d in Difficulty.values) {
      expect(d.cellCount, d.gridSize * d.gridSize);
    }
  });

  test('labels map correctly', () {
    expect(Difficulty.easy.label, 'Easy');
    expect(Difficulty.medium.label, 'Medium');
    expect(Difficulty.hard.label, 'Hard');
    expect(Difficulty.legendary.label, 'Legendary');
  });

  test('names are the stable seed-key tokens', () {
    expect(Difficulty.easy.name, 'easy');
    expect(Difficulty.medium.name, 'medium');
    expect(Difficulty.hard.name, 'hard');
    expect(Difficulty.legendary.name, 'legendary');
  });

  test('there are exactly five tiers ordered easy -> challenge', () {
    expect(Difficulty.values, [
      Difficulty.easy,
      Difficulty.medium,
      Difficulty.hard,
      Difficulty.legendary,
      Difficulty.challenge,
    ]);
  });
}
