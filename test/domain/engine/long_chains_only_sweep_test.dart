// Multi-date bot simulation for the Long Chains Only Challenge rule (added per
// Codex adversarial review, round 2 finding #4: "the full-board risk has no
// planned measurement"). Plays a naive bot (always takes the first legal
// 3-chain the search finds) across a full year of dates and checks two
// things:
//   1. A run NEVER deadlocks while empty cells remain — this is a structural
//      guarantee of GameEngine.refill (it only stops dropping once the board
//      is full OR a legal chain exists), not a fuzzy statistical claim.
//   2. The rule-aware refill/dense-start fix genuinely lets most runs play
//      out to the full move budget, rather than deadlocking almost always.
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/engine/daily_seeder.dart';
import 'package:connect_merge/domain/engine/game_engine.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/game_status.dart';

/// Finds any legal chain of exactly [minLength] tiles via the same
/// canFollow/adjacency rules [GameEngine.isValidChain] enforces, or null.
List<int>? _findChainOfLength(BoardState board, int minLength) {
  for (var start = 0; start < board.cells.length; start++) {
    if (board.cells[start] == null) continue;
    final path = <int>[start];
    final visited = <int>{start};
    if (_dfs(board, start, visited, path, minLength)) {
      return List<int>.from(path);
    }
  }
  return null;
}

bool _dfs(BoardState board, int idx, Set<int> visited, List<int> path,
    int minLength) {
  if (path.length == minLength) return GameEngine.isValidChain(board, path);
  final gs = board.gridSize;
  final row = idx ~/ gs, col = idx % gs;
  for (final n in <int>[
    if (col + 1 < gs) idx + 1,
    if (col - 1 >= 0) idx - 1,
    if (row + 1 < gs) idx + gs,
    if (row - 1 >= 0) idx - gs,
    if (row + 1 < gs && col + 1 < gs) idx + gs + 1,
    if (row + 1 < gs && col - 1 >= 0) idx + gs - 1,
    if (row - 1 >= 0 && col + 1 < gs) idx - gs + 1,
    if (row - 1 >= 0 && col - 1 >= 0) idx - gs - 1,
  ]) {
    if (visited.contains(n) || board.cells[n] == null) continue;
    path.add(n);
    visited.add(n);
    if (_dfs(board, n, visited, path, minLength)) return true;
    path.removeLast();
    visited.remove(n);
  }
  return false;
}

/// Plays a naive greedy bot (first legal 3-chain found each move) on a
/// longChainsOnly-style board for [date] until it ends, returning the final
/// board.
BoardState _playOut(String date) {
  final seeder = DailySeeder(date, Difficulty.challenge);
  var board = seeder
      .generate(startingFillOverride: kChallengeDenseFill, minChainLength: 3)
      .board;
  final dropTier = seeder.dropTierPrng();
  final landing = seeder.landingPrng();

  while (board.status == GameStatus.playing) {
    final path = _findChainOfLength(board, 3);
    if (path == null) {
      break; // shouldn't happen: status would already be deadlocked
    }
    board = GameEngine.collapseChain(board, path);
    board = GameEngine.refill(
      board,
      targetFill: kChallengeDenseFill,
      tierAt: (i) => seeder.dropTierAt(dropTier, i),
      landing: landing,
      minChainLength: 3,
    );
    board = GameEngine.evaluateStatus(board, minChainLength: 3);
  }
  return board;
}

void main() {
  test(
      'longChainsOnly bot sweep: never deadlocks with room left; most runs use the full move budget',
      () {
    var outOfMoves = 0;
    var deadlockedFull = 0;
    var deadlockedWithRoom = 0;

    for (var month = 1; month <= 12; month++) {
      for (var day = 1; day <= 28; day++) {
        final date =
            '2026-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
        final board = _playOut(date);
        switch (board.status) {
          case GameStatus.outOfMoves:
            outOfMoves++;
          case GameStatus.deadlocked:
            if (board.emptyIndices.isEmpty) {
              deadlockedFull++;
            } else {
              deadlockedWithRoom++;
            }
          case GameStatus.playing:
            fail('$date: bot loop exited without a terminal status');
        }
      }
    }

    // Structural guarantee: refill only stops dropping once the board is
    // full OR a legal chain exists, so a deadlock while cells remain empty
    // would mean refill's own postcondition was violated.
    expect(deadlockedWithRoom, 0,
        reason:
            'refill must never leave the board deadlocked with room to spare');

    // The fix's whole point: most runs should reach the full move budget
    // rather than running out of legal chains long before move 30.
    final total = outOfMoves + deadlockedFull;
    expect(total, 336);
    expect(outOfMoves, greaterThan(deadlockedFull),
        reason:
            'a naive bot should still finish most longChainsOnly runs on moves, '
            'not on a full board — outOfMoves=$outOfMoves deadlockedFull=$deadlockedFull');
  });
}
