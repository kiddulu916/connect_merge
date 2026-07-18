import 'package:flutter_bloc/flutter_bloc.dart';

import '../domain/models/difficulty.dart';
import '../infrastructure/storage_service.dart';

/// Immutable view of the chosen-rival relationship for the UI.
class RivalryState {
  /// The rival's stable player id, or null if no rival is set.
  final String? rivalId;

  /// The rival's display name, or null if no rival is set.
  final String? rivalName;

  /// Last seen rival score per tier (`difficulty.name` -> score). Drives
  /// once-per-overtake pass detection.
  final Map<String, int> lastSeenRivalScoreByTier;

  const RivalryState({
    this.rivalId,
    this.rivalName,
    this.lastSeenRivalScoreByTier = const {},
  });

  /// True when a rival is currently chosen.
  bool get hasRival => rivalId != null;

  /// Last seen rival score for [difficulty], or null if never observed.
  int? lastSeenFor(Difficulty difficulty) =>
      lastSeenRivalScoreByTier[difficulty.name];

  RivalryState copyWith({
    String? rivalId,
    String? rivalName,
    bool clearRival = false,
    Map<String, int>? lastSeenRivalScoreByTier,
  }) =>
      RivalryState(
        rivalId: clearRival ? null : (rivalId ?? this.rivalId),
        rivalName: clearRival ? null : (rivalName ?? this.rivalName),
        lastSeenRivalScoreByTier:
            lastSeenRivalScoreByTier ?? this.lastSeenRivalScoreByTier,
      );
}

/// The you-vs-rival delta on a single tier (pure value object for the UI chip).
class RivalDelta {
  final int myScore;
  final int rivalScore;

  const RivalDelta({required this.myScore, required this.rivalScore});

  /// Positive when the player is ahead, negative when behind, 0 when tied.
  int get delta => myScore - rivalScore;

  bool get amAhead => delta > 0;
  bool get amBehind => delta < 0;
  bool get tied => delta == 0;
}

/// Phase 3 rivalries. Pick a rival from already-fetched friends/leaderboard
/// rows; the app shows a persistent you-vs-them delta and fires a single local
/// "your rival passed you" nudge when a fetch shows the rival ahead on a tier
/// the player hasn't beaten today.
///
/// Rival data is sourced from rows the app already fetched — there is NO new
/// query type and NO new backend cost ($0). All ranking truth still flows
/// through the verified leaderboard; rivalries are a presentation + nudge layer.
class RivalryCubit extends Cubit<RivalryState> {
  final StorageService storage;

  RivalryCubit({required this.storage}) : super(const RivalryState());

  /// Hydrate the rival relationship from the persisted profile.
  void load() {
    final p = storage.loadProfile();
    emit(RivalryState(
      rivalId: p.rivalry.rivalId,
      rivalName: p.rivalry.rivalName,
      lastSeenRivalScoreByTier: p.rivalry.lastSeenRivalScoreByTier,
    ));
  }

  /// Choose [rivalId]/[rivalName] as the rival. Persists; clears any stale
  /// last-seen scores so a freshly chosen rival doesn't fire a spurious "passed
  /// you" nudge from a previous rival's history.
  Future<void> setRival({
    required String rivalId,
    required String rivalName,
  }) async {
    final p = storage.loadProfile();
    await storage.saveProfile(p.setRival(rivalId, rivalName));
    emit(state.copyWith(
      rivalId: rivalId,
      rivalName: rivalName,
      lastSeenRivalScoreByTier: const {},
    ));
  }

  /// Remove the current rival. Persists and clears last-seen scores.
  Future<void> clearRival() async {
    final p = storage.loadProfile();
    await storage.saveProfile(p.clearRival());
    emit(state.copyWith(
      clearRival: true,
      lastSeenRivalScoreByTier: const {},
    ));
  }

  /// Pure: did the rival just overtake the player on a tier?
  ///
  /// True only when the rival's [rivalScore] beats BOTH the player's [myScore]
  /// AND the [lastSeenRivalScore] we last reacted to — so a single overtake
  /// fires exactly one nudge, and repeated fetches with no change stay quiet.
  static bool rivalPassedMe({
    required int myScore,
    required int rivalScore,
    required int lastSeenRivalScore,
  }) =>
      rivalScore > myScore && rivalScore > lastSeenRivalScore;

  /// React to a fetched rival score on [difficulty]. Returns true when this
  /// constitutes a fresh overtake (the caller should fire the nudge). Always
  /// records the observed [rivalScore] as the new last-seen so the SAME overtake
  /// can't re-fire. A degraded/offline fetch should simply not call this (no
  /// last-seen mutation, no nudge — graceful degradation).
  Future<bool> recordRivalScore({
    required Difficulty difficulty,
    required int myScore,
    required int rivalScore,
  }) async {
    final p = storage.loadProfile();
    final lastSeen = p.rivalry.lastSeenRivalScoreByTier[difficulty.name] ?? 0;
    final passed = rivalPassedMe(
      myScore: myScore,
      rivalScore: rivalScore,
      lastSeenRivalScore: lastSeen,
    );
    // Monotonic last-seen: only advance it (never lower it on a worse fetch), so
    // a transient lower score can't re-arm the nudge for an old overtake.
    final newLastSeen = rivalScore > lastSeen ? rivalScore : lastSeen;
    if (newLastSeen != lastSeen) {
      final updated = Map<String, int>.from(p.rivalry.lastSeenRivalScoreByTier)
        ..[difficulty.name] = newLastSeen;
      await storage.saveProfile(p.copyWith(
        rivalry: p.rivalry.copyWith(lastSeenRivalScoreByTier: updated),
      ));
      emit(state.copyWith(lastSeenRivalScoreByTier: updated));
    }
    return passed;
  }
}
