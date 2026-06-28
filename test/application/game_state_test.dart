import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/application/game_state.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/game_status.dart';
import 'package:connect_merge/domain/models/tile.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';

BoardState b() => BoardState(
      cells: List<Tile?>.filled(kCellCount, null),
      movesRemaining: 30,
      score: 0,
      nextTileId: 0,
      dropIndex: 0,
      adContinuesUsed: 0,
      movesMade: 0,
      status: GameStatus.playing,
    );

void main() {
  test('state subtypes carry their payloads', () {
    expect(const GameInitial(), isA<GameState>());
    expect(
        GamePlaying(board: b(), difficulty: Difficulty.medium)
            .board
            .movesRemaining,
        30);
    final over = GameOverShowScore(
        board: b(),
        date: '2026-06-06',
        difficulty: Difficulty.hard,
        stats: LifetimeStats.empty);
    expect(over.date, '2026-06-06');
    expect(over.difficulty, Difficulty.hard);
    expect(
        GameAdRewardGranted(board: b(), difficulty: Difficulty.easy).board,
        isA<BoardState>());
  });
}
