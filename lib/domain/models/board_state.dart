import 'game_status.dart';
import 'move.dart';
import 'tile.dart';

/// Immutable snapshot of a daily board. Row-major: index = row * kGridSize + col.
class BoardState {
  final List<Tile?> cells; // length kCellCount
  final int movesRemaining;
  final int score;
  final int nextTileId; // next id to assign to a dropped tile
  final int dropIndex; // how many drops have been consumed (n)
  final int adContinuesUsed;
  final int movesMade; // total successful merges (for display incl. ad moves)
  final GameStatus status;

  /// Ordered record of state-changing player inputs (merges + ad-continues).
  /// Unused by Phase 1 UI; the authoritative input for Phase 2 replay
  /// verification. Persisted/restored with the snapshot. Defaults to empty.
  final List<MoveEvent> moveLog;

  const BoardState({
    required this.cells,
    required this.movesRemaining,
    required this.score,
    required this.nextTileId,
    required this.dropIndex,
    required this.adContinuesUsed,
    required this.movesMade,
    required this.status,
    this.moveLog = const [],
  });

  BoardState copyWith({
    List<Tile?>? cells,
    int? movesRemaining,
    int? score,
    int? nextTileId,
    int? dropIndex,
    int? adContinuesUsed,
    int? movesMade,
    GameStatus? status,
    List<MoveEvent>? moveLog,
  }) {
    return BoardState(
      cells: cells ?? this.cells,
      movesRemaining: movesRemaining ?? this.movesRemaining,
      score: score ?? this.score,
      nextTileId: nextTileId ?? this.nextTileId,
      dropIndex: dropIndex ?? this.dropIndex,
      adContinuesUsed: adContinuesUsed ?? this.adContinuesUsed,
      movesMade: movesMade ?? this.movesMade,
      status: status ?? this.status,
      moveLog: moveLog ?? this.moveLog,
    );
  }

  List<int> get emptyIndices {
    final out = <int>[];
    for (var i = 0; i < cells.length; i++) {
      if (cells[i] == null) out.add(i);
    }
    return out;
  }

  int get filledCount {
    var n = 0;
    for (final c in cells) {
      if (c != null) n++;
    }
    return n;
  }

  int get highestTier {
    var m = 0;
    for (final c in cells) {
      if (c != null && c.tier > m) m = c.tier;
    }
    return m;
  }

  Map<String, dynamic> toJson() => {
        'cells': cells.map((c) => c?.toJson()).toList(),
        'movesRemaining': movesRemaining,
        'score': score,
        'nextTileId': nextTileId,
        'dropIndex': dropIndex,
        'adContinuesUsed': adContinuesUsed,
        'movesMade': movesMade,
        'status': status.name,
        'moveLog': moveLog.map((e) => e.toJson()).toList(),
      };

  static BoardState fromJson(Map<String, dynamic> j) {
    final rawCells = j['cells'] as List;
    final rawLog = j['moveLog'] as List?; // absent in pre-tier snapshots
    return BoardState(
      cells: rawCells
          .map((e) => e == null
              ? null
              : Tile.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      movesRemaining: j['movesRemaining'] as int,
      score: j['score'] as int,
      nextTileId: j['nextTileId'] as int,
      dropIndex: j['dropIndex'] as int,
      adContinuesUsed: j['adContinuesUsed'] as int,
      movesMade: j['movesMade'] as int,
      status: GameStatus.values.byName(j['status'] as String),
      moveLog: rawLog == null
          ? const []
          : rawLog
              .map((e) =>
                  MoveEvent.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList(),
    );
  }
}
