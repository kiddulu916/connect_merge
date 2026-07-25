// Characterization test for ConnectMergeApp / _ConnectMergeAppState
// (lib/main.dart), written BEFORE splitting that state class's account-flow
// methods into a mixin (see docs/superpowers or the codebase-rehab audit for
// context). Pins down the behavior a mixin extraction must not change:
// which screen `build()` selects for a given (needsDisplayName, showAuthGate,
// recoveryRequired) combination, and the two ValueNotifier-driven UI reactions
// (_onSuperseded's dialog, _showReferralMessage's snackbar) that don't require
// a real AuthService to exercise.
//
// Deliberately NOT covered here (needs a fake AuthService/ProfileSyncService,
// already covered by their own dedicated tests): the AuthGateScreen and
// DisplayNameScreen branches of build() (see
// test/application/account_flow_controller_test.dart and
// test/presentation/display_name_screen_test.dart), Google sign-in/adopt
// flows, deep-link duel routing, and account deletion/sign-out.
import 'dart:io';

import 'package:connect_merge/application/engagement_cubit.dart';
import 'package:connect_merge/application/game_session_factory.dart';
import 'package:connect_merge/application/loot_cubit.dart';
import 'package:connect_merge/domain/models/friend.dart';
import 'package:connect_merge/infrastructure/ad_service.dart';
import 'package:connect_merge/infrastructure/hive_storage_service.dart';
import 'package:connect_merge/infrastructure/notification_service.dart';
import 'package:connect_merge/infrastructure/redeem_coordinator.dart';
import 'package:connect_merge/main.dart';
import 'package:connect_merge/presentation/screens/tier_select_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  late HiveStorageService storage;

  setUp(() async {
    Hive.init(
        '${Directory.systemTemp.path}/connect_merge_main_test_${DateTime.now().microsecondsSinceEpoch}');
    storage = HiveStorageService();
    await storage.init();
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
  });

  ConnectMergeApp buildApp({
    bool needsDisplayName = false,
    bool showAuthGate = false,
    bool recoveryRequired = false,
    ValueNotifier<bool>? superseded,
    ValueNotifier<String?>? referralMessage,
  }) {
    final engagement = EngagementCubit(storage: storage)..load();
    final loot = LootCubit(storage: storage)..load();
    return ConnectMergeApp(
      storage: storage,
      adService: AdService(),
      engagement: engagement,
      loot: loot,
      sessions: GameSessionFactory(
          storage: storage, engagement: engagement, loot: loot),
      notifications: NotificationService.withSeams(
        schedule: (_) async {},
        cancel: (_) async {},
        requestPermission: () async => false,
      ),
      superseded: superseded ?? ValueNotifier<bool>(false),
      redeemCoordinator: RedeemCoordinator(
        loadSnapshot: () => null,
        saveSnapshot: (_) async {},
        redeemCode: (_) async => const RedeemResult(RedeemStatus.error),
        onboardingReady: () => false,
        hasGoogleIdentity: () => false,
      ),
      referralReady: ValueNotifier<bool>(false),
      referralMessage: referralMessage ?? ValueNotifier<String?>(null),
      needsDisplayName: needsDisplayName,
      showAuthGate: showAuthGate,
      recoveryRequired: recoveryRequired,
    );
  }

  testWidgets('default state (no gates) shows TierSelectScreen',
      (tester) async {
    await tester.pumpWidget(buildApp());
    expect(find.byType(TierSelectScreen), findsOneWidget);
  });

  testWidgets(
      'showAuthGate/needsDisplayName without a signed-in auth still falls '
      'through to TierSelectScreen (both gated screens require widget.auth)',
      (tester) async {
    // This pins a real, slightly surprising invariant: without an AuthService,
    // _accountFlow stays null, so the `_showAuthGate && _accountFlow != null`
    // and `_needsDisplayName && widget.auth != null` branches in build() can
    // never trigger, no matter what the flags say — TierSelectScreen is the
    // fallback. A refactor that made these flags win unconditionally would be
    // a behavior change this test would catch.
    await tester.pumpWidget(
        buildApp(showAuthGate: true, needsDisplayName: true));
    expect(find.byType(TierSelectScreen), findsOneWidget);
  });

  testWidgets('recoveryRequired shows the restore-failed screen',
      (tester) async {
    await tester.pumpWidget(buildApp(recoveryRequired: true));
    expect(
      find.text('Your cloud profile could not be restored safely.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'Retry restore'), findsOneWidget);
    expect(find.byType(TierSelectScreen), findsNothing);
  });

  testWidgets('MaterialApp shell has the expected title and dark theme',
      (tester) async {
    await tester.pumpWidget(buildApp());
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.title, 'Connect Merge');
    expect(app.theme?.brightness, Brightness.dark);
  });

  testWidgets(
      'setting superseded shows the "profile opened elsewhere" dialog',
      (tester) async {
    final superseded = ValueNotifier<bool>(false);
    await tester.pumpWidget(buildApp(superseded: superseded));
    expect(find.text('Profile opened elsewhere'), findsNothing);

    superseded.value = true;
    await tester.pumpAndSettle();

    expect(find.text('Profile opened elsewhere'), findsOneWidget);
    expect(
      find.text(
        "Your profile was opened on another device. Progress on this "
        "device isn't being saved.",
      ),
      findsOneWidget,
    );
  });

  testWidgets('setting referralMessage shows it in a snackbar',
      (tester) async {
    final referralMessage = ValueNotifier<String?>(null);
    await tester.pumpWidget(buildApp(referralMessage: referralMessage));

    referralMessage.value = 'Friend added!';
    await tester.pump();
    await tester.pump(); // post-frame callback that calls showSnackBar

    // findsWidgets (not findsOneWidget): the SnackBar's enter transition can
    // render both the incoming and outgoing frame's Text in the tree at this
    // pump point — a rendering-animation artifact, not a duplicate snackbar.
    expect(find.text('Friend added!'), findsWidgets);
    // The message is a one-shot: the notifier resets to null once consumed.
    expect(referralMessage.value, isNull);
  });

  testWidgets('app lifecycle changes do not throw without a profileSync',
      (tester) async {
    await tester.pumpWidget(buildApp());
    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    // No exception thrown by dispose() either.
    await tester.pumpWidget(const SizedBox());
  });
}
