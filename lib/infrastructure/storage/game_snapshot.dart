import '../../domain/constants.dart';
import '../../domain/models/board_state.dart';
import '../../domain/models/difficulty.dart';

/// A persisted in-progress (or finished) day for a single difficulty tier.
class GameSnapshot {
  final String date; // YYYY-MM-DD (UTC) this snapshot belongs to
  final Difficulty difficulty; // which tier this snapshot belongs to
  final BoardState board;
  final bool completed; // true once the day is locked

  /// Snapshot schema version. A snapshot whose version != [kSnapshotVersion] is
  /// discarded on load (the cubit starts the day fresh under current rules).
  final int version;

  const GameSnapshot({
    required this.date,
    required this.difficulty,
    required this.board,
    required this.completed,
    this.version = kSnapshotVersion,
  });

  Map<String, dynamic> toJson() => {
        'date': date,
        'difficulty': difficulty.name,
        'board': board.toJson(),
        'completed': completed,
        'v': version,
      };

  static GameSnapshot fromJson(Map<String, dynamic> j) => GameSnapshot(
        date: j['date'] as String,
        difficulty: Difficulty.values.byName(j['difficulty'] as String),
        board:
            BoardState.fromJson(Map<String, dynamic>.from(j['board'] as Map)),
        completed: j['completed'] as bool,
        version: (j['v'] as int?) ?? 1,
      );
}
