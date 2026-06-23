import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:merge_count/domain/constants.dart';
import 'package:merge_count/domain/models/difficulty.dart';
import 'package:merge_count/domain/models/friend.dart';
import 'package:merge_count/infrastructure/friends_service.dart';

String _sha(String s) => sha256.convert(utf8.encode(s)).toString();

/// Builds a service with no-op seams, overriding only what a test needs.
FriendsService _service({
  RpcResultFn? rpc,
  InvokeMapFn? invoke,
  TableInsertFn? insert,
  TableDeleteFn? deleteMine,
  TableSelectFn? selectMine,
}) {
  return FriendsService.withSeams(
    rpc: rpc ?? (_, __) async => null,
    invoke: invoke ?? (_, __) async => const {},
    insert: insert ?? (_, __) async {},
    deleteMine: deleteMine ?? (_) async {},
    selectMine: selectMine ?? (_) async => const [],
  );
}

void main() {
  group('myFriendCode', () {
    test('calls ensure_friend_code and returns the scalar code', () async {
      String? fn;
      final s = _service(rpc: (f, _) async {
        fn = f;
        return 'ABCD2345';
      });
      expect(await s.myFriendCode(), 'ABCD2345');
      expect(fn, 'ensure_friend_code');
    });

    test('unwraps a single-element list result', () async {
      final s = _service(rpc: (_, __) async => ['WXYZ7654']);
      expect(await s.myFriendCode(), 'WXYZ7654');
    });
  });

  group('inviteLink', () {
    test('builds the custom-scheme deep link', () {
      expect(FriendsService.inviteLink('ABCD2345'),
          'connectmerge://invite/ABCD2345');
    });
    test('builds the https fallback', () {
      expect(FriendsService.inviteHttpsLink('ABCD2345'),
          'https://mergecount.app/invite/ABCD2345');
    });
  });

  group('redeemCode', () {
    test('passes the trimmed code to redeem_code and maps ok', () async {
      String? fn;
      Map<String, dynamic>? params;
      final s = _service(rpc: (f, p) async {
        fn = f;
        params = p;
        return {'ok': true, 'friend_id': 'friend-uuid'};
      });
      final res = await s.redeemCode('  ABCD2345  ');
      expect(fn, 'redeem_code');
      expect(params, {'p_code': 'ABCD2345'});
      expect(res.ok, isTrue);
      expect(res.status, RedeemStatus.ok);
      expect(res.friendId, 'friend-uuid');
    });

    test('maps self-add rejection', () async {
      final s = _service(rpc: (_, __) async => {'ok': false, 'reason': 'self'});
      final res = await s.redeemCode('mycode');
      expect(res.ok, isFalse);
      expect(res.status, RedeemStatus.self);
    });

    test('maps invalid code', () async {
      final s = _service(
          rpc: (_, __) async => {'ok': false, 'reason': 'invalid_code'});
      final res = await s.redeemCode('nope');
      expect(res.status, RedeemStatus.invalidCode);
    });

    test('maps duplicate (ok again -> still ok, idempotent)', () async {
      // Redeeming twice returns ok both times (server ON CONFLICT DO NOTHING).
      final s = _service(
          rpc: (_, __) async => {'ok': true, 'friend_id': 'friend-uuid'});
      final res = await s.redeemCode('ABCD2345');
      expect(res.ok, isTrue);
    });
  });

  group('friendsLeaderboard', () {
    test('shapes the RPC call and maps rows to LeaderboardEntry', () async {
      String? fn;
      Map<String, dynamic>? params;
      final s = _service(rpc: (f, p) async {
        fn = f;
        params = p;
        return [
          {'rank': 1, 'display_name': 'Me', 'score': 900, 'is_me': true},
          {'rank': 2, 'display_name': 'Pat', 'score': 700, 'is_me': false},
        ];
      });
      final rows = await s.friendsLeaderboard(
          difficulty: Difficulty.hard, date: '2026-06-07');
      expect(fn, 'friends_leaderboard');
      expect(params,
          {'p_date': '2026-06-07', 'p_diff': 'hard', 'p_season': kLeaderboardSeason});
      expect(rows.length, 2);
      expect(rows[0].isMe, isTrue);
      expect(rows[1].displayName, 'Pat');
    });

    test('zero friends who played -> just you (single row)', () async {
      final s = _service(rpc: (_, __) async => [
            {'rank': 1, 'display_name': 'Me', 'score': 100, 'is_me': true}
          ]);
      final rows = await s.friendsLeaderboard(
          difficulty: Difficulty.easy, date: '2026-06-07');
      expect(rows.length, 1);
      expect(rows.single.isMe, isTrue);
    });
  });

  group('contacts opt-in (privacy: only hashes leave the device)', () {
    test('optInContacts stores ONLY normalized SHA256 hashes', () async {
      String? table;
      List<Map<String, dynamic>>? rows;
      final s = _service(insert: (t, r) async {
        table = t;
        rows = r;
      });
      await s.optInContacts(['+1 (415) 555-0100', 'Me@Example.com']);
      expect(table, 'contact_hashes');
      // Raw values must NOT appear anywhere in the payload.
      final asString = rows.toString();
      expect(asString.contains('415'), isFalse);
      expect(asString.toLowerCase().contains('example.com'), isFalse);
      // Only the expected hashes are sent.
      final hashes = rows!.map((r) => r['hash']).toSet();
      expect(hashes, contains(_sha('+14155550100')));
      expect(hashes, contains(_sha('me@example.com')));
    });

    test('revokeContacts deletes stored hashes', () async {
      String? table;
      final s = _service(deleteMine: (t) async => table = t);
      await s.revokeContacts();
      expect(table, 'contact_hashes');
    });

    test('isOptedInToContacts reflects stored rows', () async {
      expect(await _service(selectMine: (_) async => const []).isOptedInToContacts(),
          isFalse);
      expect(
          await _service(selectMine: (_) async => [
                {'hash': 'x'}
              ]).isOptedInToContacts(),
          isTrue);
    });
  });

  group('matchContacts (privacy: posts hashes, not raw contacts)', () {
    test('hashes on device and posts only hashes; maps matched players',
        () async {
      String? fn;
      Map<String, dynamic>? body;
      final s = _service(invoke: (f, b) async {
        fn = f;
        body = b;
        return {
          'matches': [
            {'playerId': 'p1', 'displayName': 'Ada'}
          ]
        };
      });
      final matches = await s.matchContacts(['+1 (415) 555-0100']);
      expect(fn, 'match-contacts');
      final sentHashes = (body!['hashes'] as List).cast<String>();
      expect(sentHashes, [_sha('+14155550100')]);
      // No raw contact in the payload.
      expect(body.toString().contains('415'), isFalse);
      expect(matches.single,
          const Friend(playerId: 'p1', displayName: 'Ada'));
    });

    test('empty/unhashable contacts -> no call, empty result', () async {
      var called = false;
      final s = _service(invoke: (_, __) async {
        called = true;
        return const {};
      });
      final matches = await s.matchContacts(['   ', '']);
      expect(called, isFalse);
      expect(matches, isEmpty);
    });
  });
}
