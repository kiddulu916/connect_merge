import 'package:connect_merge/presentation/screens/auth_gate_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('offers Google and guest without allowing concurrent actions',
      (tester) async {
    var googleCalls = 0;
    var guestCalls = 0;
    await tester.pumpWidget(MaterialApp(
      home: AuthGateScreen(
        onGoogle: () async {
          googleCalls++;
          return true;
        },
        onGuest: () async {
          guestCalls++;
          return true;
        },
      ),
    ));

    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Play as guest'), findsOneWidget);
    await tester.tap(find.byKey(const Key('continue-google')));
    await tester.pump();
    expect(googleCalls, 1);
    expect(guestCalls, 0);
  });

  testWidgets('surfaces a retryable action failure', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AuthGateScreen(
        onGoogle: () async => throw StateError('offline'),
        onGuest: () async => true,
      ),
    ));

    await tester.tap(find.byKey(const Key('continue-google')));
    await tester.pump();
    expect(find.byKey(const Key('auth-gate-error')), findsOneWidget);
  });

  testWidgets('a cancelled Google collision re-enables both choices',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AuthGateScreen(
        onGoogle: () async => false,
        onGuest: () async => true,
      ),
    ));

    await tester.tap(find.byKey(const Key('continue-google')));
    await tester.pump();
    final google = tester.widget<FilledButton>(
      find.byKey(const Key('continue-google')),
    );
    final guest = tester.widget<OutlinedButton>(
      find.byKey(const Key('play-guest')),
    );
    expect(google.onPressed, isNotNull);
    expect(guest.onPressed, isNotNull);
  });
}
