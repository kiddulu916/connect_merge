import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/models/daily_objective.dart';

void main() {
  test('chainLength objective tracks the max chain seen', () {
    const o = DailyObjective(kind: ObjectiveKind.chainLength, target: 5);
    var p = 0;
    p = o.progressAfter(p, chainLength: 3, highestTier: 4);
    expect(p, 3);
    p = o.progressAfter(p, chainLength: 2, highestTier: 6); // shorter chain
    expect(p, 3); // does not regress
    p = o.progressAfter(p, chainLength: 5, highestTier: 6);
    expect(p, 5);
    expect(o.isMet(p), isTrue);
    expect(o.isMet(4), isFalse);
  });

  test('reachTier objective tracks the highest tier seen', () {
    const o = DailyObjective(kind: ObjectiveKind.reachTier, target: 8);
    var p = 0;
    p = o.progressAfter(p, chainLength: 9, highestTier: 5);
    expect(p, 5);
    p = o.progressAfter(p, chainLength: 2, highestTier: 8);
    expect(p, 8);
    expect(o.isMet(p), isTrue);
  });

  test('label is human readable', () {
    expect(const DailyObjective(kind: ObjectiveKind.chainLength, target: 5).label,
        contains('5'));
    expect(const DailyObjective(kind: ObjectiveKind.reachTier, target: 8).label,
        contains('8'));
  });
}
