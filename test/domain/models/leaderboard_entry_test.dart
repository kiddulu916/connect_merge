import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/models/leaderboard_entry.dart';

void main() {
  group('LeaderboardEntry.fromJson', () {
    test('maps snake_case RPC columns incl. is_me', () {
      final e = LeaderboardEntry.fromJson({
        'rank': 3,
        'display_name': 'Grace',
        'score': 1500,
        'is_me': true,
      });
      expect(e.rank, 3);
      expect(e.displayName, 'Grace');
      expect(e.score, 1500);
      expect(e.isMe, isTrue);
    });

    test('coerces numeric rank/score from num (Postgres bigint/int)', () {
      final e = LeaderboardEntry.fromJson({
        'rank': 10,
        'display_name': 'Linus',
        'score': 42,
        'is_me': false,
      });
      expect(e.rank, isA<int>());
      expect(e.score, isA<int>());
      expect(e.rank, 10);
      expect(e.score, 42);
    });

    test('defaults is_me to false when null/absent', () {
      final e = LeaderboardEntry.fromJson({
        'rank': 1,
        'display_name': 'Anon',
        'score': 0,
        'is_me': null,
      });
      expect(e.isMe, isFalse);
    });

    test('maps player_id when present (friends daily board)', () {
      final e = LeaderboardEntry.fromJson({
        'rank': 2,
        'display_name': 'Nadia',
        'score': 800,
        'is_me': false,
        'player_id': 'rival-1',
      });
      expect(e.playerId, 'rival-1');
    });

    test('player_id is null when absent (global/period boards)', () {
      final e = LeaderboardEntry.fromJson({
        'rank': 1,
        'display_name': 'Anon',
        'score': 0,
        'is_me': false,
      });
      expect(e.playerId, isNull);
    });

    test('value equality includes player_id', () {
      const a = LeaderboardEntry(
          rank: 1, displayName: 'A', score: 5, isMe: false);
      const b = LeaderboardEntry(
          rank: 1, displayName: 'A', score: 5, isMe: false);
      const c = LeaderboardEntry(
          rank: 1, displayName: 'A', score: 5, isMe: true);
      const d = LeaderboardEntry(
          rank: 1, displayName: 'A', score: 5, isMe: false, playerId: 'x');
      expect(a, equals(b));
      expect(a == c, isFalse);
      expect(a == d, isFalse);
    });
  });
}
