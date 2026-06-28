import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/engine/daily_seeder.dart';
import 'package:connect_merge/domain/engine/game_engine.dart';
import 'package:connect_merge/domain/models/difficulty.dart';

void main() {
  test('same date+tier yields identical initial board and drop tiers', () {
    final a = const DailySeeder('2026-06-06', Difficulty.medium).generate();
    final b = const DailySeeder('2026-06-06', Difficulty.medium).generate();
    expect(a.board.toJson(), b.board.toJson());
    expect(a.dropTiers, b.dropTiers);
  });

  test('different dates differ (same tier)', () {
    final a = const DailySeeder('2026-06-06', Difficulty.medium).generate();
    final b = const DailySeeder('2026-06-07', Difficulty.medium).generate();
    expect(a.board.toJson(), isNot(b.board.toJson()));
  });

  test('different tiers on same date produce different boards', () {
    final easy = const DailySeeder('2026-06-06', Difficulty.easy).generate();
    final hard = const DailySeeder('2026-06-06', Difficulty.hard).generate();
    expect(easy.board.toJson(), isNot(hard.board.toJson()));
    // Drop schedules also differ because the seed key differs.
    expect(easy.dropTiers, isNot(hard.dropTiers));
  });

  test('each tier places exactly its startingFill tiles, all tier 1-2', () {
    for (final d in Difficulty.values) {
      final start = DailySeeder('2026-06-06', d).generate();
      expect(start.board.filledCount, d.startingFill,
          reason: '${d.name} should place ${d.startingFill} tiles');
      for (final c in start.board.cells) {
        if (c != null) expect(c.tier, inInclusiveRange(1, 2));
      }
    }
  });

  test('tile counts are 40/25/20/15 for easy/medium/hard/legendary', () {
    expect(const DailySeeder('2026-06-06', Difficulty.easy)
        .generate()
        .board
        .filledCount, 40);
    expect(const DailySeeder('2026-06-06', Difficulty.medium)
        .generate()
        .board
        .filledCount, 25);
    expect(const DailySeeder('2026-06-06', Difficulty.hard)
        .generate()
        .board
        .filledCount, 20);
    expect(const DailySeeder('2026-06-06', Difficulty.legendary)
        .generate()
        .board
        .filledCount, 15);
  });

  test('generated board has correct gridSize and cell count per difficulty', () {
    for (final d in Difficulty.values) {
      final board = DailySeeder('2026-06-06', d).generate().board;
      expect(board.gridSize, d.gridSize,
          reason: '${d.name} board.gridSize should be ${d.gridSize}');
      expect(board.cells.length, d.cellCount,
          reason: '${d.name} cells.length should be ${d.cellCount}');
    }
  });

  test('drop schedule has kMaxDrops tiers, each within its band', () {
    final start =
        const DailySeeder('2026-06-06', Difficulty.medium).generate();
    expect(start.dropTiers.length, kMaxDrops);
    for (var n = 0; n < start.dropTiers.length; n++) {
      expect(start.dropTiers[n], inInclusiveRange(1, dropCap(n)));
    }
  });

  test('landingPrng is independent of dropTier draws and reproducible', () {
    const s = DailySeeder('2026-06-06', Difficulty.medium);
    final p1 = s.landingPrng();
    final p2 = s.landingPrng();
    expect(List.generate(10, (_) => p1.nextU32()),
        List.generate(10, (_) => p2.nextU32()));
  });

  test('seedForKey is deterministic and key-sensitive', () {
    expect(DailySeeder.seedForKey('2026-06-06:hard'),
        DailySeeder.seedForKey('2026-06-06:hard'));
    expect(DailySeeder.seedForKey('2026-06-06:hard'),
        isNot(DailySeeder.seedForKey('2026-06-06:easy')));
  });

  group('goldenDropIndices (Phase 1)', () {
    test('same date+tier yields an identical golden set across runs', () {
      final a = const DailySeeder('2026-06-06', Difficulty.medium)
          .goldenDropIndices();
      final b = const DailySeeder('2026-06-06', Difficulty.medium)
          .goldenDropIndices();
      expect(a, b);
    });

    test('indices are within the drop range', () {
      final set = const DailySeeder('2026-06-06', Difficulty.hard)
          .goldenDropIndices();
      for (final n in set) {
        expect(n, inInclusiveRange(0, kMaxDrops - 1));
      }
    });

    test('different dates/tiers generally produce different sets', () {
      final a = const DailySeeder('2026-06-06', Difficulty.medium)
          .goldenDropIndices();
      final b = const DailySeeder('2026-06-07', Difficulty.medium)
          .goldenDropIndices();
      final c = const DailySeeder('2026-06-06', Difficulty.hard)
          .goldenDropIndices();
      expect(a, isNot(b));
      expect(a, isNot(c));
    });

    test('golden stream is independent of board/drop generation', () {
      // Generating the board first must not perturb the golden set.
      const s = DailySeeder('2026-06-06', Difficulty.medium);
      final beforeGen = s.goldenDropIndices();
      s.generate();
      final afterGen = s.goldenDropIndices();
      expect(beforeGen, afterGen);
    });

    test('golden density is in a sane, rare-ish range over a sample', () {
      var total = 0;
      var golden = 0;
      final start = DateTime.utc(2026, 1, 1);
      for (var i = 0; i < 200; i++) {
        final date = start.add(Duration(days: i));
        final key =
            '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
        final set = DailySeeder(key, Difficulty.medium).goldenDropIndices();
        golden += set.length;
        total += kMaxDrops;
      }
      final ratio = golden / total;
      // Centred on kGoldenDropPercent (~8%); allow generous slack.
      expect(ratio, greaterThan(0.02));
      expect(ratio, lessThan(0.18));
    });
  });

  group('Connect-Merge seeding', () {
    test('wallIndices is deterministic and sized per difficulty', () {
      final s = DailySeeder('2026-06-20', Difficulty.hard);
      expect(s.wallIndices().length, wallCountFor(Difficulty.hard));
      expect(s.wallIndices(), DailySeeder('2026-06-20', Difficulty.hard).wallIndices());
    });

    test('easy has wallCountFor(easy) walls (currently 2)', () {
      final walls = DailySeeder('2026-06-20', Difficulty.easy).wallIndices();
      expect(walls.length, wallCountFor(Difficulty.easy));
    });

    test('generated board carries walls and never places a tile on one', () {
      final s = DailySeeder('2026-06-20', Difficulty.legendary);
      final start = s.generate();
      expect(start.board.walls, s.wallIndices());
      for (final w in start.board.walls) {
        expect(start.board.cells[w], isNull);
      }
      expect(start.board.filledCount, Difficulty.legendary.startingFill);
    });
  });

  group('Connect-Merge drops & objective', () {
    test('drop-tier stream is deterministic and band-capped by index', () {
      final s = DailySeeder('2026-06-20', Difficulty.medium);
      final p1 = s.dropTierPrng();
      final p2 = s.dropTierPrng();
      for (var n = 0; n < 50; n++) {
        final t1 = s.dropTierAt(p1, n);
        final t2 = s.dropTierAt(p2, n);
        expect(t1, t2); // same seed => same sequence
        expect(t1 >= 1 && t1 <= dropCap(n), isTrue);
      }
    });

    test('dailyObjective is deterministic and valid', () {
      final s = DailySeeder('2026-06-20', Difficulty.medium);
      final o = s.dailyObjective();
      expect(o.target > 0, isTrue);
      expect(s.dailyObjective().kind, o.kind);
      expect(s.dailyObjective().target, o.target);
    });
  });

  group('born-deadlock prevention (I-1)', () {
    // Checks that no generated board is born-dead (no adjacent same-tier pair).
    // Covers all difficulties across two months + spot months to catch sparse
    // legendary dates. At least ~40 date/difficulty combos including legendary.
    test('no born-dead boards across 2026-06 days 1..28, all difficulties', () {
      for (var day = 1; day <= 28; day++) {
        final date =
            '2026-06-${day.toString().padLeft(2, '0')}';
        for (final d in Difficulty.values) {
          final board = DailySeeder(date, d).generate().board;
          expect(
            GameEngine.hasMergeAvailable(board),
            isTrue,
            reason: 'Born-dead board: $date ${d.name}',
          );
        }
      }
    });

    test('no born-dead boards across 2026-01 days 1..28, all difficulties', () {
      for (var day = 1; day <= 28; day++) {
        final date =
            '2026-01-${day.toString().padLeft(2, '0')}';
        for (final d in Difficulty.values) {
          final board = DailySeeder(date, d).generate().board;
          expect(
            GameEngine.hasMergeAvailable(board),
            isTrue,
            reason: 'Born-dead board: $date ${d.name}',
          );
        }
      }
    });

    test('no born-dead boards spot-check other months', () {
      // Check a sample across 2026-02, 2026-03, 2026-05 to widen coverage.
      for (final month in [2, 3, 5]) {
        for (var day = 1; day <= 28; day++) {
          final date =
              '2026-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
          for (final d in Difficulty.values) {
            final board = DailySeeder(date, d).generate().board;
            expect(
              GameEngine.hasMergeAvailable(board),
              isTrue,
              reason: 'Born-dead board: $date ${d.name}',
            );
          }
        }
      }
    });

    test('determinism still holds after re-roll logic', () {
      // Same date+difficulty must always produce bit-identical cells.
      for (final d in Difficulty.values) {
        final a = DailySeeder('2026-06-01', d).generate();
        final b = DailySeeder('2026-06-01', d).generate();
        expect(a.board.toJson(), b.board.toJson(),
            reason: 'Board not deterministic for ${d.name}');
      }
    });

    test('filledCount == startingFill after re-roll', () {
      for (final d in Difficulty.values) {
        final start = DailySeeder('2026-01-02', d).generate();
        expect(start.board.filledCount, d.startingFill,
            reason: '${d.name} should have ${d.startingFill} tiles');
      }
    });

    test('walls are unchanged by re-roll', () {
      // The walls stream is independent and must not shift.
      for (final d in Difficulty.values) {
        final s = DailySeeder('2026-06-04', d);
        final walls = s.wallIndices();
        final board = s.generate().board;
        expect(board.walls, walls,
            reason: 'Walls changed for ${d.name}');
      }
    });
  });
}
