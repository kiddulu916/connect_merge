import 'package:flutter_bloc/flutter_bloc.dart';

import '../domain/constants.dart';
import '../domain/engine/daily_seeder.dart';
import '../domain/engine/game_engine.dart';
import '../domain/engine/prng.dart';
import '../domain/models/board_state.dart';
import '../domain/models/game_status.dart';
import '../infrastructure/storage_service.dart';
import 'game_state.dart';

/// Formats a DateTime as the canonical YYYY-MM-DD seeding key (local date).
String formatDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Orchestrates the daily game. **Call [init] before any other method** —
/// `merge`/`grantAdReward` rely on fields set up there (they are also guarded
/// by the state machine, which starts in [GameInitial]).
class GameCubit extends Cubit<GameState> {
  final StorageService storage;
  final String Function() todayProvider;

  late String _date;
  late List<int> _dropTiers;
  late Prng _landing;

  GameCubit({
    required this.storage,
    String Function()? todayProvider,
  })  : todayProvider = todayProvider ?? (() => formatDate(DateTime.now())),
        super(const GameInitial());

  Future<void> init() async {
    _date = todayProvider();
    final seeder = DailySeeder(_date);
    final start = seeder.generate();
    _dropTiers = start.dropTiers;

    final snap = storage.loadSnapshot();
    if (snap != null && snap.date == _date) {
      // Resume today: rebuild the landing stream to the saved position.
      _landing = seeder.landingPrng();
      for (var i = 0; i < snap.board.dropIndex; i++) {
        _landing.nextU32();
      }
      if (snap.completed || snap.board.status != GameStatus.playing) {
        emit(GameOverShowScore(
            board: snap.board, date: _date, stats: storage.loadStats()));
      } else {
        emit(GamePlaying(board: snap.board));
      }
      return;
    }

    // Fresh day.
    _landing = seeder.landingPrng();
    await storage.saveSnapshot(
        GameSnapshot(date: _date, board: start.board, completed: false));
    emit(GamePlaying(board: start.board));
  }

  Future<void> merge({required int fromIndex, required int toIndex}) async {
    final s = state;
    if (s is! GamePlaying) return;
    if (!GameEngine.canMerge(s.board, fromIndex, toIndex)) return;

    var board = GameEngine.merge(s.board, fromIndex: fromIndex, toIndex: toIndex);
    if (board.dropIndex < _dropTiers.length) {
      board = GameEngine.applyDrop(board, _dropTiers[board.dropIndex], _landing);
    }
    board = GameEngine.evaluateStatus(board);

    final done = board.status != GameStatus.playing;
    await storage.saveSnapshot(
        GameSnapshot(date: _date, board: board, completed: done));

    if (done) {
      final stats = await _recordCompletion(board);
      emit(GameOverShowScore(board: board, date: _date, stats: stats));
    } else {
      emit(GamePlaying(board: board));
    }
  }

  /// True when the player ran out of moves, a merge still exists, and the daily
  /// ad-continue allowance is not exhausted. Deadlock is never ad-revivable.
  bool get canOfferAd {
    final s = state;
    return s is GameOverShowScore &&
        s.board.status == GameStatus.outOfMoves &&
        s.board.adContinuesUsed < kMaxAdContinuesPerDay &&
        GameEngine.hasMergeAvailable(s.board);
  }

  Future<void> grantAdReward() async {
    final s = state;
    if (s is! GameOverShowScore) return;
    final board = s.board.copyWith(
      movesRemaining: s.board.movesRemaining + kAdMoveReward,
      adContinuesUsed: s.board.adContinuesUsed + 1,
      status: GameStatus.playing,
    );
    await storage.saveSnapshot(
        GameSnapshot(date: _date, board: board, completed: false));
    emit(GameAdRewardGranted(board: board));
    emit(GamePlaying(board: board));
  }

  /// Update lifetime stats once per completed day (idempotent within a day via
  /// lastCompletedDate guard).
  Future<LifetimeStats> _recordCompletion(BoardState board) async {
    final prev = storage.loadStats();
    if (prev.lastCompletedDate == _date) return prev;

    final yesterday = formatDate(
        DateTime.parse(_date).subtract(const Duration(days: 1)));
    final streak = prev.lastCompletedDate == yesterday ? prev.streak + 1 : 1;

    final updated = prev.copyWith(
      streak: streak,
      lastCompletedDate: _date,
      bestScore: board.score > prev.bestScore ? board.score : prev.bestScore,
      bestTier:
          board.highestTier > prev.bestTier ? board.highestTier : prev.bestTier,
    );
    await storage.saveStats(updated);
    return updated;
  }
}
