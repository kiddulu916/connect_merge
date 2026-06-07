import '../domain/models/board_state.dart';
import '../domain/models/difficulty.dart';
import '../infrastructure/storage_service.dart';

sealed class GameState {
  const GameState();
}

class GameInitial extends GameState {
  const GameInitial();
}

class GamePlaying extends GameState {
  final BoardState board;
  final Difficulty difficulty;
  const GamePlaying({required this.board, required this.difficulty});
}

class GameOverShowScore extends GameState {
  final BoardState board;
  final String date;
  final Difficulty difficulty;
  final LifetimeStats stats;
  const GameOverShowScore({
    required this.board,
    required this.date,
    required this.difficulty,
    required this.stats,
  });
}

/// Transient state emitted immediately before resuming play after a rewarded
/// ad, so the UI can flash feedback. The cubit emits GamePlaying right after.
class GameAdRewardGranted extends GameState {
  final BoardState board;
  final Difficulty difficulty;
  const GameAdRewardGranted({required this.board, required this.difficulty});
}
