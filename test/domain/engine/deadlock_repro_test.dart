// Reproduction harness for the "board locks after ~2 merges" report.
//
// It plays each difficulty the way the cubit's playChain does: collapse a
// legal Connect-Merge chain, then refill to the difficulty's startingFill by
// dropping into RANDOM empty cells (landing PRNG), then evaluateStatus. We play
// GREEDILY-OPTIMAL (always take the longest available chain) so the numbers are
// the BEST case a perfect player could achieve — if even that deadlocks fast,
// the balance is broken.
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/engine/daily_seeder.dart';
import 'package:connect_merge/domain/engine/game_engine.dart';
import 'package:connect_merge/domain/engine/prng.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/game_status.dart';

/// Find the longest same-tier orthogonally-adjacent simple path on the board,
/// via greedy DFS from every live tile. Returns [] if no chain (length>=2).
List<int> longestChain(BoardState s) {
  final gs = s.gridSize;
  List<int> best = const [];
  for (var start = 0; start < s.cells.length; start++) {
    final t = s.cells[start];
    if (t == null || t.tier >= kMaxTier) continue;
    final path = <int>[start];
    final seen = <int>{start};
    void dfs(int cur) {
      if (path.length > best.length) best = List<int>.of(path);
      final row = cur ~/ gs, col = cur % gs;
      for (final n in [
        if (col + 1 < gs) cur + 1,
        if (col - 1 >= 0) cur - 1,
        if (row + 1 < gs) cur + gs,
        if (row - 1 >= 0) cur - gs,
      ]) {
        final nt = s.cells[n];
        if (nt == null || nt.tier != t.tier || seen.contains(n)) continue;
        seen.add(n);
        path.add(n);
        dfs(n);
        path.removeLast();
        seen.remove(n);
      }
    }
    dfs(start);
  }
  return best.length >= 2 ? best : const [];
}

/// Intentionally simulates the PRE-FIX refill strategy (fill to startingFill,
/// no hasMergeAvailable guarantee) to measure how often it deadlocks.
BoardState refill(BoardState board, DailySeeder seeder, Prng dropTier,
    Prng landing, int targetFill) {
  while (board.filledCount < targetFill && board.emptyIndices.isNotEmpty) {
    final tier = seeder.dropTierAt(dropTier, board.dropIndex);
    board = GameEngine.applyDrop(board, tier, landing);
  }
  return board;
}

void main() {
  for (final d in Difficulty.values) {
    test('merges-before-death — ${d.name}', () {
      final mergeCounts = <int>[];
      const dates = 200;
      for (var day = 0; day < dates; day++) {
        final date = '2026-${(1 + day % 12).toString().padLeft(2, '0')}'
            '-${(1 + day % 28).toString().padLeft(2, '0')}';
        final seeder = DailySeeder(date, d);
        var board = seeder.generate().board;
        final landing = seeder.landingPrng();
        final dropTier = seeder.dropTierPrng();

        var merges = 0;
        while (true) {
          board = GameEngine.evaluateStatus(board);
          if (board.status != GameStatus.playing) break;
          final chain = longestChain(board);
          if (chain.isEmpty) break;
          board = GameEngine.collapseChain(board, chain);
          board = refill(board, seeder, dropTier, landing, d.startingFill);
          merges++;
          if (merges > 100) break; // safety
        }
        mergeCounts.add(merges);
      }
      mergeCounts.sort();
      final avg = mergeCounts.reduce((a, b) => a + b) / mergeCounts.length;
      final median = mergeCounts[mergeCounts.length ~/ 2];
      final stuckAt2OrLess =
          mergeCounts.where((m) => m <= 2).length / mergeCounts.length;
      // ignore: avoid_print
      print('${d.name.padRight(10)} fill=${d.startingFill} '
          'avg=${avg.toStringAsFixed(1)} median=$median '
          'min=${mergeCounts.first} max=${mergeCounts.last} '
          '<=2 merges: ${(stuckAt2OrLess * 100).toStringAsFixed(0)}% of days');
      expect(mergeCounts, isNotEmpty);
    });
  }
}
