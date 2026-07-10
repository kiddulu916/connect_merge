import 'package:flutter_bloc/flutter_bloc.dart';

import '../domain/models/difficulty.dart';
import '../domain/models/duel_challenge.dart';

/// Immutable view of an in-flight async duel for the UI.
class DuelState {
  /// The incoming challenge the player was invited to, or null when none.
  final DuelChallenge? challenge;

  /// The recipient's own score on the challenged board once they've played it,
  /// or null before they complete that `(date, difficulty)`.
  final int? myScore;

  /// The settled outcome once both scores are known, or null otherwise.
  final DuelOutcome? outcome;

  /// True once the challenged date is in the past relative to "today" — the
  /// board is no longer playable, so the challenge has expired.
  final bool expired;

  const DuelState({
    this.challenge,
    this.myScore,
    this.outcome,
    this.expired = false,
  });

  /// True when there is an active (non-expired) challenge awaiting a play.
  bool get hasChallenge => challenge != null && !expired;

  DuelState copyWith({
    DuelChallenge? challenge,
    bool clearChallenge = false,
    int? myScore,
    bool clearMyScore = false,
    DuelOutcome? outcome,
    bool clearOutcome = false,
    bool? expired,
  }) =>
      DuelState(
        challenge: clearChallenge ? null : (challenge ?? this.challenge),
        myScore: clearMyScore ? null : (myScore ?? this.myScore),
        outcome: clearOutcome ? null : (outcome ?? this.outcome),
        expired: expired ?? this.expired,
      );
}

/// Phase 3 async duels. Holds an incoming [DuelChallenge], compares it against
/// the recipient's own run on the IDENTICAL seeded `(date, difficulty)` board,
/// and offers a share-back link.
///
/// The challenger's score is DISPLAY-ONLY — it is NEVER written to or used to
/// rank any leaderboard row. Ranking truth stays in the verified leaderboard;
/// this cubit only compares two scores locally for a friendly result. That is
/// why a forged (hand-edited) link can mislead the recipient's *displayed*
/// target but can never pollute rankings, and why no backend is needed ($0).
class DuelCubit extends Cubit<DuelState> {
  final String Function() todayProvider;

  /// Optional analytics hook (observability). Signature matches
  /// `AnalyticsService.logEvent` exactly.
  final void Function(String name, [Map<String, Object?>? params])?
      onAnalyticsEvent;

  DuelCubit({required this.todayProvider, this.onAnalyticsEvent})
      : super(const DuelState());

  /// Accept an incoming [challenge] (from a duel deep link). Marks it expired
  /// when its date is no longer today (the seeded board is gone), so the UI can
  /// offer today's tier instead. Resets any prior comparison.
  void receiveChallenge(DuelChallenge challenge) {
    final expired = challenge.date != todayProvider();
    emit(DuelState(challenge: challenge, expired: expired));
    if (!expired) {
      onAnalyticsEvent
          ?.call('duel_started', {'difficulty': challenge.difficulty.name});
    }
  }

  /// Clear the current challenge (e.g. after the player dismisses the banner).
  void dismiss() => emit(const DuelState());

  /// Report the recipient's [myScore] on a completed [date]/[difficulty] board.
  /// Only settles the duel when it matches the active challenge's board (the
  /// same-board guarantee that makes the comparison honest); otherwise it's a
  /// no-op so an unrelated tier completion never settles a duel.
  void recordMyResult({
    required String date,
    required Difficulty difficulty,
    required int myScore,
  }) {
    final c = state.challenge;
    if (c == null) return;
    // An expired challenge's board is no longer playable, so it can never be
    // honestly settled — guard before any comparison.
    if (state.expired) return;
    if (c.date != date || c.difficulty != difficulty) return;
    final outcome = compare(myScore: myScore, challengerScore: c.challengerScore);
    emit(state.copyWith(myScore: myScore, outcome: outcome));
    onAnalyticsEvent?.call('duel_completed', {
      'difficulty': difficulty.name,
      'won': outcome == DuelOutcome.win,
    });
  }

  /// Pure comparison: the recipient's [myScore] vs the challenger's claimed
  /// [challengerScore].
  static DuelOutcome compare({
    required int myScore,
    required int challengerScore,
  }) {
    if (myScore > challengerScore) return DuelOutcome.win;
    if (myScore < challengerScore) return DuelOutcome.lose;
    return DuelOutcome.tie;
  }

  /// Build a fresh duel link the recipient can send BACK, carrying their own
  /// result on the same board. Pure helper — encoding is owned by the model.
  static DuelChallenge shareBack({
    required String date,
    required Difficulty difficulty,
    required String myName,
    required int myScore,
  }) =>
      DuelChallenge(
        date: date,
        difficulty: difficulty,
        challengerName: myName,
        challengerScore: myScore,
      );
}
