import 'package:flutter_test/flutter_test.dart';
import 'package:merge_count/application/game_cubit.dart';
import 'package:merge_count/application/game_state.dart';
import 'package:merge_count/domain/constants.dart';
import 'package:merge_count/domain/models/difficulty.dart';
import 'package:merge_count/infrastructure/storage_service.dart';

GameCubit freshCubit() => GameCubit(
    storage: InMemoryStorageService(), todayProvider: () => '2026-06-20');

void main() {
  test('same date+difficulty yields identical boards and identical play results',
      () async {
    final a = freshCubit();
    final b = freshCubit();
    await a.init(difficulty: Difficulty.hard);
    await b.init(difficulty: Difficulty.hard);

    final ba = (a.state as GamePlaying).board;
    final bb = (b.state as GamePlaying).board;
    // Identical seeded boards for two players.
    for (var i = 0; i < kCellCount; i++) {
      expect(ba.cells[i]?.tier, bb.cells[i]?.tier);
    }
    expect(ba.walls, bb.walls);
    expect(a.objective.kind, b.objective.kind);
    expect(a.objective.target, b.objective.target);

    // Same chain on both => same score + same queue afterward.
    int? from, to;
    for (var i = 0; i < kCellCount && from == null; i++) {
      final t = ba.cells[i];
      if (t == null || t.tier >= kMaxTier) continue;
      for (final n in [i + 1, i + kGridSize]) {
        if (n >= kCellCount) continue;
        if (n == i + 1 && (i % kGridSize) == kGridSize - 1) continue;
        final u = ba.cells[n];
        if (u != null && u.tier == t.tier) { from = i; to = n; break; }
      }
    }
    await a.playChain([from!, to!]);
    await b.playChain([from, to]);
    expect((a.state as GamePlaying).board.score,
        (b.state as GamePlaying).board.score);
    expect(a.peekDropTiers(), b.peekDropTiers());
  });
}
