import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/application/engagement_cubit.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/models/avatar.dart';
import 'package:connect_merge/infrastructure/auth_service.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:connect_merge/presentation/screens/avatars_screen.dart';

void main() {
  late InMemoryStorageService storage;
  EngagementCubit make() =>
      EngagementCubit(storage: storage, todayProvider: () => '2026-06-12');

  setUp(() => storage = InMemoryStorageService());

  testWidgets('buying then selecting a locked avatar writes through to the server',
      (tester) async {
    await storage
        .saveProfile(const PlayerProfile(wallet: Wallet(coins: kAvatarPrice)));
    final engagement = make()..load();
    addTearDown(engagement.close);
    final auth = _FakeAuth();

    await tester.pumpWidget(MaterialApp(
      home: AvatarsScreen(engagement: engagement, auth: auth),
    ));
    await tester.pump(); // flush refreshWallet + server sync

    final wolf = find.byKey(const Key('avatar-wolf'));
    expect(wolf, findsOneWidget);

    // First tap on a locked, affordable avatar => purchase.
    await tester.tap(wolf);
    await tester.pump();
    expect(engagement.state.unlockedAvatars, contains(Avatar.wolf));
    expect(storage.loadProfile().wallet.coins, 0);

    // Second tap, now unlocked => select + server write-through.
    await tester.tap(wolf);
    await tester.pump();
    expect(engagement.state.selectedAvatar, Avatar.wolf.emoji);
    expect(auth.updatedAvatars, contains(Avatar.wolf.emoji));
  });

  testWidgets('a free avatar is selectable without buying', (tester) async {
    final engagement = make()..load();
    addTearDown(engagement.close);
    final auth = _FakeAuth();

    await tester.pumpWidget(MaterialApp(
      home: AvatarsScreen(engagement: engagement, auth: auth),
    ));
    await tester.pump();

    await tester.tap(find.byKey(const Key('avatar-panda')));
    await tester.pump();
    expect(engagement.state.selectedAvatar, Avatar.panda.emoji);
    expect(auth.updatedAvatars, contains(Avatar.panda.emoji));
  });
}

/// Minimal AuthService fake: captures avatar writes, no live client.
class _FakeAuth implements AuthService {
  final updatedAvatars = <String>[];

  @override
  Future<void> updateAvatar(String avatar) async => updatedAvatars.add(avatar);

  @override
  Future<({String? name, String? avatar})> profile() async =>
      (name: 'Ann', avatar: '🦊');

  @override
  String? get currentUserId => 'fake-user-id';

  @override
  Future<void> setDisplayName(String name, {String? avatar}) async {}

  @override
  Future<void> deleteAccount() async {}

  @override
  Future<void> ensureSignedIn() async {}

  @override
  Future<String?> displayName() async => 'Ann';

  @override
  Future<bool> hasDisplayName() async => true;

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
