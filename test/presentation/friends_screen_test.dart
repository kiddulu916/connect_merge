import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/models/friend.dart';
import 'package:connect_merge/infrastructure/friends_service.dart';
import 'package:connect_merge/presentation/screens/friends_screen.dart';

FriendsService _service({
  RpcResultFn? rpc,
  InvokeMapFn? invoke,
}) {
  return FriendsService.withSeams(
    rpc: rpc ?? (fn, _) async {
      if (fn == 'ensure_friend_code') return 'MYCODE12';
      if (fn == 'friends_leaderboard') return const [];
      return null;
    },
    invoke: invoke ?? (_, __) async => const {},
    insert: (_, __) async {},
    deleteMine: (_) async {},
    selectMine: (_) async => const [],
  );
}

void main() {
  testWidgets('shows the player friend code and privacy note', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: FriendsScreen(
        service: _service(),
        todayProvider: () => '2026-06-07',
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('my-friend-code')), findsOneWidget);
    expect(find.text('MYCODE12'), findsOneWidget);
    // Privacy is non-negotiable: the rationale must state contacts stay on device.
    final note = tester.widget<Text>(
        find.byKey(const Key('contacts-privacy-note')));
    expect(note.data, contains('never leave your device'));
  });

  testWidgets('friends leaderboard empty state renders', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: FriendsScreen(
        service: _service(),
        todayProvider: () => '2026-06-07',
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fl-empty')), findsOneWidget);
  });

  testWidgets('redeeming a code shows a success status', (tester) async {
    final service = _service(rpc: (fn, _) async {
      if (fn == 'ensure_friend_code') return 'MYCODE12';
      if (fn == 'friends_leaderboard') return const [];
      if (fn == 'redeem_code') return {'ok': true, 'friend_id': 'f1'};
      return null;
    });
    await tester.pumpWidget(MaterialApp(
      home: FriendsScreen(
        service: service,
        todayProvider: () => '2026-06-07',
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('code-input')), 'FRIEND01');
    await tester.tap(find.byKey(const Key('redeem-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('friends-status')), findsOneWidget);
    expect(find.text('Friend added!'), findsOneWidget);
  });

  testWidgets('invalid code shows an inline error (no crash)', (tester) async {
    final service = _service(rpc: (fn, _) async {
      if (fn == 'ensure_friend_code') return 'MYCODE12';
      if (fn == 'friends_leaderboard') return const [];
      if (fn == 'redeem_code') {
        return {'ok': false, 'reason': 'invalid_code'};
      }
      return null;
    });
    await tester.pumpWidget(MaterialApp(
      home: FriendsScreen(
        service: service,
        todayProvider: () => '2026-06-07',
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('code-input')), 'BADCODE0');
    await tester.tap(find.byKey(const Key('redeem-button')));
    await tester.pumpAndSettle();

    expect(find.text("We couldn't find that code."), findsOneWidget);
  });

  testWidgets('contacts permission denied falls back gracefully',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: FriendsScreen(
        service: _service(),
        todayProvider: () => '2026-06-07',
        loadContacts: () async => null, // denied
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('match-contacts-button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('permission denied'), findsOneWidget);
  });

  testWidgets('matched contacts render in the list', (tester) async {
    var capturedHashes = <dynamic>[];
    final service = FriendsService.withSeams(
      rpc: (fn, _) async {
        if (fn == 'ensure_friend_code') return 'MYCODE12';
        if (fn == 'friends_leaderboard') return const [];
        return null;
      },
      invoke: (fn, body) async {
        capturedHashes = (body['hashes'] as List?) ?? const [];
        return {
          'matches': [
            {'playerId': 'p1', 'displayName': 'Ada'}
          ]
        };
      },
      insert: (_, __) async {},
      deleteMine: (_) async {},
      selectMine: (_) async => const [],
    );

    await tester.pumpWidget(MaterialApp(
      home: FriendsScreen(
        service: service,
        todayProvider: () => '2026-06-07',
        loadContacts: () async => ['+1 (415) 555-0100'],
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('match-contacts-button')));
    await tester.pumpAndSettle();

    // The raw number must NOT have been sent — only a hash.
    expect(capturedHashes.length, 1);
    expect(capturedHashes.first.toString().contains('415'), isFalse);
    expect(find.byKey(const Key('matched-p1')), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
  });

  testWidgets('tapping Invite shares the invite link', (tester) async {
    String? shared;
    await tester.pumpWidget(MaterialApp(
      home: FriendsScreen(
        service: _service(),
        todayProvider: () => '2026-06-07',
        shareInvite: (t) async => shared = t,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('invite-button')));
    await tester.pumpAndSettle();

    expect(shared, contains('connectmerge://invite/MYCODE12'));
  });

  test('Friend.fromJson handles snake_case and camelCase', () {
    expect(
      Friend.fromJson(const {'player_id': 'p1', 'display_name': 'A'}),
      const Friend(playerId: 'p1', displayName: 'A'),
    );
    expect(
      Friend.fromJson(const {'playerId': 'p2', 'displayName': 'B'}),
      const Friend(playerId: 'p2', displayName: 'B'),
    );
  });
}
