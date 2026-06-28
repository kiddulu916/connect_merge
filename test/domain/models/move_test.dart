import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/models/move.dart';

void main() {
  test('MergeEvent round-trips through json', () {
    const e = MergeEvent(from: 3, to: 7);
    final decoded = MoveEvent.fromJson(e.toJson());
    expect(decoded, isA<MergeEvent>());
    expect(decoded, e);
    expect((decoded as MergeEvent).from, 3);
    expect(decoded.to, 7);
  });

  test('ContinueEvent round-trips through json', () {
    const e = ContinueEvent();
    final decoded = MoveEvent.fromJson(e.toJson());
    expect(decoded, isA<ContinueEvent>());
    expect(decoded, e);
  });

  test('a mixed log round-trips in order', () {
    final log = <MoveEvent>[
      const MergeEvent(from: 0, to: 1),
      const MergeEvent(from: 2, to: 3),
      const ContinueEvent(),
      const MergeEvent(from: 4, to: 5),
    ];
    final restored = log
        .map((e) => MoveEvent.fromJson(e.toJson()))
        .toList(growable: false);
    expect(restored, log);
  });

  test('equality distinguishes merge endpoints and event types', () {
    expect(const MergeEvent(from: 1, to: 2) == const MergeEvent(from: 1, to: 2),
        isTrue);
    expect(const MergeEvent(from: 1, to: 2) == const MergeEvent(from: 2, to: 1),
        isFalse);
    expect(const ContinueEvent() == const ContinueEvent(), isTrue);
    expect(const MergeEvent(from: 1, to: 2) == const ContinueEvent(), isFalse);
  });

  test('unknown type throws', () {
    expect(() => MoveEvent.fromJson({'type': 'bogus'}), throwsArgumentError);
  });

  test('ChainEvent round-trips through json and preserves order', () {
    const e = ChainEvent(path: [0, 1, 6, 11]);
    final decoded = MoveEvent.fromJson(e.toJson());
    expect(decoded, isA<ChainEvent>());
    expect(decoded, e);
    expect((decoded as ChainEvent).path, [0, 1, 6, 11]);
  });

  test('ChainEvent equality is order-sensitive', () {
    expect(const ChainEvent(path: [0, 1, 2]) == const ChainEvent(path: [0, 1, 2]),
        isTrue);
    expect(const ChainEvent(path: [0, 1, 2]) == const ChainEvent(path: [2, 1, 0]),
        isFalse);
  });
}
