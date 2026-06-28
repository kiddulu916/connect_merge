import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/application/duel_cubit.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/duel_challenge.dart';

void main() {
  const challenge = DuelChallenge(
    date: '2026-06-11',
    difficulty: Difficulty.hard,
    challengerName: 'Ann',
    challengerScore: 1000,
  );

  DuelCubit makeToday() => DuelCubit(todayProvider: () => '2026-06-11');

  group('DuelCubit.compare (pure)', () {
    test('win when my score exceeds the challenger', () {
      expect(DuelCubit.compare(myScore: 1500, challengerScore: 1000),
          DuelOutcome.win);
    });
    test('lose when my score is below the challenger', () {
      expect(DuelCubit.compare(myScore: 800, challengerScore: 1000),
          DuelOutcome.lose);
    });
    test('tie when equal', () {
      expect(DuelCubit.compare(myScore: 1000, challengerScore: 1000),
          DuelOutcome.tie);
    });
  });

  group('DuelCubit receive + settle', () {
    test('receiving a today challenge is active (not expired)', () {
      final c = makeToday()..receiveChallenge(challenge);
      expect(c.state.hasChallenge, isTrue);
      expect(c.state.expired, isFalse);
      expect(c.state.challenge, challenge);
    });

    test('settles WIN on the same (date,diff) board', () {
      final c = makeToday()..receiveChallenge(challenge);
      c.recordMyResult(
          date: '2026-06-11', difficulty: Difficulty.hard, myScore: 1500);
      expect(c.state.myScore, 1500);
      expect(c.state.outcome, DuelOutcome.win);
    });

    test('settles LOSE / TIE correctly', () {
      final lose = makeToday()..receiveChallenge(challenge);
      lose.recordMyResult(
          date: '2026-06-11', difficulty: Difficulty.hard, myScore: 500);
      expect(lose.state.outcome, DuelOutcome.lose);

      final tie = makeToday()..receiveChallenge(challenge);
      tie.recordMyResult(
          date: '2026-06-11', difficulty: Difficulty.hard, myScore: 1000);
      expect(tie.state.outcome, DuelOutcome.tie);
    });

    test('same-board guarantee: a different DATE does not settle the duel', () {
      final c = makeToday()..receiveChallenge(challenge);
      c.recordMyResult(
          date: '2026-06-12', difficulty: Difficulty.hard, myScore: 9999);
      expect(c.state.outcome, isNull);
      expect(c.state.myScore, isNull);
    });

    test('same-board guarantee: a different TIER does not settle the duel', () {
      final c = makeToday()..receiveChallenge(challenge);
      c.recordMyResult(
          date: '2026-06-11', difficulty: Difficulty.easy, myScore: 9999);
      expect(c.state.outcome, isNull);
    });

    test('a challenge for a PAST date is marked expired', () {
      final c = DuelCubit(todayProvider: () => '2026-06-12')
        ..receiveChallenge(challenge); // challenge.date == 2026-06-11
      expect(c.state.expired, isTrue);
      expect(c.state.hasChallenge, isFalse);
    });

    test('an expired challenge never settles (no outcome) even on its board',
        () {
      // "Today" is past the challenge date, so the board is gone (expired).
      final c = DuelCubit(todayProvider: () => '2026-06-12')
        ..receiveChallenge(challenge); // challenge.date == 2026-06-11
      expect(c.state.expired, isTrue);
      // Recording a result for the challenged (date,diff) board must NOT settle.
      c.recordMyResult(
          date: '2026-06-11', difficulty: Difficulty.hard, myScore: 9999);
      expect(c.state.outcome, isNull);
      expect(c.state.myScore, isNull);
    });

    test('dismiss clears the challenge', () {
      final c = makeToday()..receiveChallenge(challenge);
      c.dismiss();
      expect(c.state.challenge, isNull);
    });
  });

  group('DuelCubit share-back', () {
    test('builds a fresh challenge link carrying my own result', () {
      final back = DuelCubit.shareBack(
        date: '2026-06-11',
        difficulty: Difficulty.hard,
        myName: 'Bob',
        myScore: 1500,
      );
      // The link round-trips to the same display-only payload.
      final decoded = DuelChallenge.fromUri(back.toUri());
      expect(decoded, back);
      expect(decoded?.challengerName, 'Bob');
      expect(decoded?.challengerScore, 1500);
    });

    test('a forged high score in a link is display-only: it never feeds '
        'ranking — only the local comparison sees it', () {
      // Simulate a hand-edited link claiming an impossible score.
      final forged =
          DuelChallenge.fromString('connectmerge://duel/2026-06-11/hard/999999/Mallory');
      expect(forged, isNotNull);
      final c = makeToday()..receiveChallenge(forged!);
      // The recipient's real run on the SAME board loses to the fake target,
      // but nothing here writes to any leaderboard row — the cubit only holds
      // the displayed challenge + a local outcome.
      c.recordMyResult(
          date: '2026-06-11', difficulty: Difficulty.hard, myScore: 2000);
      expect(c.state.outcome, DuelOutcome.lose);
      // The only mutated state is the local comparison; the challenge payload is
      // unchanged and there is no leaderboard surface on this cubit at all.
      expect(c.state.challenge!.challengerScore, 999999);
    });
  });
}
