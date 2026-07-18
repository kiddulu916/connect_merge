import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/infrastructure/auth_service.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:connect_merge/presentation/screens/profile_screen.dart';

void main() {
  testWidgets('shows the display name and Player ID', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ProfileScreen(
        auth: _FakeAuthService(),
        storage: InMemoryStorageService(),
      ),
    ));
    await tester.pump(); // flush the profile() load

    expect(find.text('Ann'), findsOneWidget);
    expect(find.text('fake-user-id'), findsOneWidget);
  });

  testWidgets('confirmed delete wipes storage, deletes account, fires callback',
      (tester) async {
    final auth = _FakeAuthService();
    final storage = InMemoryStorageService();
    await storage.saveProfile(const PlayerProfile(wallet: Wallet(coins: 42)));
    var deleted = false;

    await tester.pumpWidget(MaterialApp(
      home: ProfileScreen(
        auth: auth,
        storage: storage,
        onDeleted: () => deleted = true,
      ),
    ));
    await tester.pump();

    await tester.tap(find.byKey(const Key('profile-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-confirm')));
    // Not pumpAndSettle(): the delete row shows an indeterminate spinner while
    // _deleting == true, which is never reset on the success path (in
    // production the screen is popped; in this test it IS the home route, so
    // it stays mounted and the spinner would spin forever). Pump enough to
    // close the dialog and flush the async delete/wipe/callback chain.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(auth.deleteCalls, 1);
    expect(storage.loadProfile().wallet.coins, 0); // wiped back to empty
    expect(deleted, isTrue);
  });

  testWidgets('cancelled dialog deletes nothing', (tester) async {
    final auth = _FakeAuthService();

    await tester.pumpWidget(MaterialApp(
      home: ProfileScreen(auth: auth, storage: InMemoryStorageService()),
    ));
    await tester.pump();

    await tester.tap(find.byKey(const Key('profile-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-cancel')));
    await tester.pumpAndSettle();

    expect(auth.deleteCalls, 0);
  });
}

/// Minimal fake mirroring display_name_screen_test's: the real [AuthService]
/// needs a live SupabaseClient.
class _FakeAuthService implements AuthService {
  int deleteCalls = 0;

  @override
  Future<void> setDisplayName(String name, {String? avatar}) async {}

  @override
  Future<void> deleteAccount() async {
    deleteCalls++;
  }

  @override
  Future<void> ensureSignedIn() async {}

  @override
  Future<String?> displayName() async => 'Ann';

  @override
  Future<bool> hasDisplayName() async => true;

  @override
  Future<({String? name, String? avatar})> profile() async =>
      (name: 'Ann', avatar: '🦊');

  @override
  String? get currentUserId => 'fake-user-id';

  @override
  bool get isSignedIn => true;
}
