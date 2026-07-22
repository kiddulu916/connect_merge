import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/infrastructure/analytics_service.dart';
import 'package:connect_merge/infrastructure/auth_service.dart';
import 'package:connect_merge/presentation/screens/display_name_screen.dart';

void main() {
  testWidgets('a successful save logs onboarding_completed', (tester) async {
    final events = <MapEntry<String, Map<String, Object?>?>>[];
    final analytics = AnalyticsService.withSeams(
      logEvent: (name, params) async {
        events.add(MapEntry(name, params));
      },
    );
    var saved = false;

    await tester.pumpWidget(MaterialApp(
      home: DisplayNameScreen(
        auth: _FakeAuthService(),
        analytics: analytics,
        onSaved: () => saved = true,
      ),
    ));

    await tester.enterText(find.byKey(const Key('display-name-field')), 'Ann');
    await tester.tap(find.byKey(const Key('display-name-save')));
    // Not pumpAndSettle(): the Save button shows an indeterminate
    // CircularProgressIndicator while _saving == true, and _saving is never
    // reset to false on the success path (by design — production's onSaved
    // unmounts this screen before it matters). An indeterminate spinner's
    // animation never settles, so pumpAndSettle() would hang forever. Two
    // pump()s are enough to flush the fake setDisplayName's microtask and
    // the subsequent onSaved callback.
    await tester.pump();
    await tester.pump();

    expect(saved, isTrue);
    // MapEntry has no value equality — compare .key/.value directly.
    expect(events, hasLength(1));
    expect(events.single.key, 'onboarding_completed');
    expect(events.single.value, isNull);
  });

  testWidgets('a taken name shows the already-taken error', (tester) async {
    var saved = false;

    await tester.pumpWidget(MaterialApp(
      home: DisplayNameScreen(
        auth:
            _FakeAuthService(setDisplayNameError: DisplayNameTakenException()),
        onSaved: () => saved = true,
      ),
    ));

    await tester.enterText(find.byKey(const Key('display-name-field')), 'Ann');
    await tester.tap(find.byKey(const Key('display-name-save')));
    await tester.pump();
    await tester.pump();

    expect(saved, isFalse);
    expect(find.text('That name is already taken.'), findsOneWidget);
  });
}

/// Minimal fake: real [AuthService] requires a live [SupabaseClient], which
/// isn't available in a widget test. Implements exactly [AuthService]'s
/// public members (it has a private `_client` field, nothing else public).
class _FakeAuthService implements AuthService {
  final Object? setDisplayNameError;

  _FakeAuthService({this.setDisplayNameError});

  @override
  Future<void> setDisplayName(String name, {String? avatar}) async {
    final error = setDisplayNameError;
    if (error != null) throw error;
  }

  @override
  Future<void> deleteAccount() async {}

  @override
  Future<void> ensureSignedIn() async {}

  @override
  Future<String?> displayName() async => null;

  @override
  Future<bool> hasDisplayName() async => false;

  @override
  Future<({String? name, String? avatar})> profile() async =>
      (name: null, avatar: null);

  @override
  String? get currentUserId => 'fake-id';

  @override
  bool get isSignedIn => true;

  @override
  bool get hasGoogleIdentity => false;

  @override
  Future<GoogleAuthResult> signInWithGoogle() async => GoogleAuthResult.linked;

  @override
  Future<GoogleAuthResult> confirmAdopt() async => GoogleAuthResult.adopted;

  @override
  void cancelGoogleAdoption() {}

  @override
  Future<void> signOut() async {}
}
