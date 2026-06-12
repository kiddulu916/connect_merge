import 'package:flutter_test/flutter_test.dart';
import 'package:merge_count/domain/models/tile.dart';

void main() {
  test('value is 2^tier', () {
    expect(const Tile(id: 0, tier: 1).value, 2);
    expect(const Tile(id: 0, tier: 11).value, 2048);
  });

  test('equality is by id and tier', () {
    expect(const Tile(id: 1, tier: 3), const Tile(id: 1, tier: 3));
    expect(const Tile(id: 1, tier: 3), isNot(const Tile(id: 2, tier: 3)));
  });

  test('copyWith changes tier but keeps id', () {
    final t = const Tile(id: 5, tier: 2).copyWith(tier: 3);
    expect(t.id, 5);
    expect(t.tier, 3);
  });

  test('round-trips through json', () {
    const t = Tile(id: 7, tier: 4);
    expect(Tile.fromJson(t.toJson()), t);
  });

  group('golden (Phase 1)', () {
    test('defaults to false', () {
      expect(const Tile(id: 0, tier: 1).golden, isFalse);
    });

    test('absent golden key in json => false (migration-free)', () {
      final t = Tile.fromJson({'id': 3, 'tier': 2});
      expect(t.golden, isFalse);
    });

    test('non-golden tile omits the golden key (byte-compatible)', () {
      expect(const Tile(id: 1, tier: 2).toJson().containsKey('golden'), isFalse);
    });

    test('golden round-trips and participates in equality', () {
      const g = Tile(id: 9, tier: 5, golden: true);
      expect(g.toJson()['golden'], isTrue);
      expect(Tile.fromJson(g.toJson()), g);
      expect(g, isNot(const Tile(id: 9, tier: 5)));
    });

    test('copyWith toggles golden, keeps id', () {
      final g = const Tile(id: 5, tier: 2).copyWith(golden: true);
      expect(g.id, 5);
      expect(g.golden, isTrue);
    });
  });
}
