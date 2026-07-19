import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/move.dart';
import 'package:connect_merge/infrastructure/leaderboard_service.dart';

void main() {
  group('LeaderboardService.submitRun', () {
    test('sends move log (not a score) with date + difficulty', () async {
      String? capturedFn;
      Map<String, dynamic>? capturedBody;
      final service = LeaderboardService.withSeams(
        invoke: (fn, body) async {
          capturedFn = fn;
          capturedBody = body;
          return {'valid': true, 'score': 1240, 'highestTier': 7, 'rank': 42};
        },
        rpc: (_, __) async => const [],
      );

      final result = await service.submitRun(
        date: '2026-06-07',
        difficulty: Difficulty.hard,
        moveLog: const [
          MergeEvent(from: 3, to: 8),
          MergeEvent(from: 1, to: 2),
          ContinueEvent(),
        ],
      );

      expect(capturedFn, 'submit-score');
      expect(capturedBody!['date'], '2026-06-07');
      expect(capturedBody!['difficulty'], 'hard');
      // The client must NOT send a score — only the move log.
      expect(capturedBody!.containsKey('score'), isFalse);
      expect(capturedBody!['moveLog'], [
        {'type': 'merge', 'from': 3, 'to': 8},
        {'type': 'merge', 'from': 1, 'to': 2},
        {'type': 'continue'},
      ]);

      expect(result.valid, isTrue);
      expect(result.score, 1240);
      expect(result.highestTier, 7);
      expect(result.rank, 42);
    });

    test('maps a rejected (invalid) run response', () async {
      final service = LeaderboardService.withSeams(
        invoke: (_, __) async => {'valid': false, 'reason': 'invalid_run'},
        rpc: (_, __) async => const [],
      );
      final result = await service.submitRun(
        date: '2026-06-07',
        difficulty: Difficulty.easy,
        moveLog: const [],
      );
      expect(result.valid, isFalse);
      expect(result.score, 0);
      expect(result.rank, 0);
    });

    test('propagates transport errors so callers can retry', () async {
      final service = LeaderboardService.withSeams(
        invoke: (_, __) async => throw Exception('network down'),
        rpc: (_, __) async => const [],
      );
      expect(
        () => service.submitRun(
          date: '2026-06-07',
          difficulty: Difficulty.easy,
          moveLog: const [],
        ),
        throwsException,
      );
    });
  });

  group('LeaderboardService.fetch', () {
    test('calls the leaderboard RPC with date/diff/limit and maps rows',
        () async {
      String? capturedFn;
      Map<String, dynamic>? capturedParams;
      final service = LeaderboardService.withSeams(
        invoke: (_, __) async => const {},
        rpc: (fn, params) async {
          capturedFn = fn;
          capturedParams = params;
          return [
            {'rank': 1, 'display_name': 'Ada', 'score': 980, 'is_me': false},
            {'rank': 2, 'display_name': 'Me', 'score': 870, 'is_me': true},
          ];
        },
      );

      final entries = await service.fetch(
        difficulty: Difficulty.legendary,
        date: '2026-06-07',
        limit: 50,
      );

      expect(capturedFn, 'leaderboard');
      expect(capturedParams, {
        'p_date': '2026-06-07',
        'p_diff': 'legendary',
        'p_limit': 50,
        'p_season': kLeaderboardSeason,
      });
      expect(entries.length, 2);
      expect(entries[0].rank, 1);
      expect(entries[0].displayName, 'Ada');
      expect(entries[0].isMe, isFalse);
      expect(entries[1].isMe, isTrue);
      expect(entries[1].score, 870);
    });

    test('returns an empty list when there are no scores', () async {
      final service = LeaderboardService.withSeams(
        invoke: (_, __) async => const {},
        rpc: (_, __) async => const [],
      );
      final entries =
          await service.fetch(difficulty: Difficulty.easy, date: '2026-06-07');
      expect(entries, isEmpty);
    });
  });

  group('LeaderboardService.fetchPeriod (extended leaderboards)', () {
    test('calls leaderboard_period with diff + date range and maps total',
        () async {
      String? capturedFn;
      Map<String, dynamic>? capturedParams;
      final service = LeaderboardService.withSeams(
        invoke: (_, __) async => const {},
        rpc: (fn, params) async {
          capturedFn = fn;
          capturedParams = params;
          return [
            {'rank': 1, 'display_name': 'Ada', 'total': 5400, 'is_me': true},
            {'rank': 2, 'display_name': 'Bo', 'total': 5100, 'is_me': false},
          ];
        },
      );

      final entries = await service.fetchPeriod(
        difficulty: Difficulty.medium,
        from: '2026-06-01',
        to: '2026-06-07',
      );

      expect(capturedFn, 'leaderboard_period');
      expect(capturedParams, {
        'p_diff': 'medium',
        'p_from': '2026-06-01',
        'p_to': '2026-06-07',
        'p_season': kLeaderboardSeason,
      });
      // The RPC's `total` column maps onto LeaderboardEntry.score.
      expect(entries[0].score, 5400);
      expect(entries[0].isMe, isTrue);
      expect(entries[1].displayName, 'Bo');
    });
  });

  group('LeaderboardService caller-rank RPCs', () {
    test('myDailyRanks shapes the range payload and groups ranks by date',
        () async {
      String? capturedFn;
      Map<String, dynamic>? capturedParams;
      final service = LeaderboardService.withSeams(
        invoke: (_, __) async => const {},
        rpc: (fn, params) async {
          capturedFn = fn;
          capturedParams = params;
          return [
            {'utc_date': '2026-06-20', 'difficulty': 'easy', 'rank': 5},
            {'utc_date': '2026-06-20', 'difficulty': 'hard', 'rank': 2},
            {'utc_date': '2026-06-21', 'difficulty': 'challenge', 'rank': 10},
          ];
        },
      );

      final ranks = await service.myDailyRanks(
        from: '2026-06-20',
        to: '2026-06-21',
      );

      expect(capturedFn, 'my_daily_ranks');
      expect(capturedParams, {
        'p_from': '2026-06-20',
        'p_to': '2026-06-21',
        'p_season': kLeaderboardSeason,
      });
      expect(ranks, {
        '2026-06-20': {Difficulty.easy: 5, Difficulty.hard: 2},
        '2026-06-21': {Difficulty.challenge: 10},
      });
    });

    test('myPeriodRanks shapes the range payload and maps tier ranks',
        () async {
      String? capturedFn;
      Map<String, dynamic>? capturedParams;
      final service = LeaderboardService.withSeams(
        invoke: (_, __) async => const {},
        rpc: (fn, params) async {
          capturedFn = fn;
          capturedParams = params;
          return [
            {'difficulty': 'medium', 'rank': 5},
            {'difficulty': 'legendary', 'rank': 1},
          ];
        },
      );

      final ranks = await service.myPeriodRanks(
        from: '2026-06-01',
        to: '2026-06-30',
      );

      expect(capturedFn, 'my_period_ranks');
      expect(capturedParams, {
        'p_from': '2026-06-01',
        'p_to': '2026-06-30',
        'p_season': kLeaderboardSeason,
      });
      expect(ranks, {Difficulty.medium: 5, Difficulty.legendary: 1});
    });
  });

  group('LeaderboardService season tagging (Task 17)', () {
    test('submitRun payload includes the current season', () async {
      Map<String, dynamic>? capturedBody;
      final service = LeaderboardService.withSeams(
        invoke: (fn, body) async {
          capturedBody = body;
          return {'valid': true, 'score': 500, 'highestTier': 5, 'rank': 10};
        },
        rpc: (_, __) async => const [],
      );

      await service.submitRun(
        date: '2026-06-20',
        difficulty: Difficulty.medium,
        moveLog: const [MergeEvent(from: 1, to: 2)],
      );

      expect(capturedBody!['season'], kLeaderboardSeason);
    });

    test('fetch passes the current season to the leaderboard RPC', () async {
      Map<String, dynamic>? capturedParams;
      final service = LeaderboardService.withSeams(
        invoke: (_, __) async => const {},
        rpc: (fn, params) async {
          capturedParams = params;
          return [];
        },
      );

      await service.fetch(
        difficulty: Difficulty.hard,
        date: '2026-06-20',
      );

      expect(capturedParams!['p_season'], kLeaderboardSeason);
    });

    test('fetchPeriod passes the current season to the leaderboard_period RPC',
        () async {
      Map<String, dynamic>? capturedParams;
      final service = LeaderboardService.withSeams(
        invoke: (_, __) async => const {},
        rpc: (fn, params) async {
          capturedParams = params;
          return [];
        },
      );

      await service.fetchPeriod(
        difficulty: Difficulty.easy,
        from: '2026-06-01',
        to: '2026-06-20',
      );

      expect(capturedParams!['p_season'], kLeaderboardSeason);
    });
  });
}
