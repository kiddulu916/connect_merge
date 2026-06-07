import 'package:flutter_test/flutter_test.dart';
import 'package:merge_loop/domain/models/difficulty.dart';

void main() {
  test('starting tile counts are 10/8/6/4', () {
    expect(Difficulty.easy.startingFill, 10);
    expect(Difficulty.medium.startingFill, 8);
    expect(Difficulty.hard.startingFill, 6);
    expect(Difficulty.legendary.startingFill, 4);
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

  test('there are exactly four tiers ordered easy -> legendary', () {
    expect(Difficulty.values, [
      Difficulty.easy,
      Difficulty.medium,
      Difficulty.hard,
      Difficulty.legendary,
    ]);
  });
}
