import 'package:connect_merge/application/engagement_cubit.dart';
import 'package:connect_merge/application/game_session_factory.dart';
import 'package:connect_merge/application/loot_cubit.dart';
import 'package:connect_merge/infrastructure/ad_service.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:connect_merge/presentation/screens/game_screen.dart';
import 'package:connect_merge/presentation/screens/tier_select_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('injected session factory drives the pushed game route',
      (tester) async {
    final storage = InMemoryStorageService();
    await storage.saveProfile(storage.loadProfile().copyWith(
          settings: storage.loadProfile().settings.copyWith(tutorialSeen: true),
        ));
    final engagement = EngagementCubit(storage: storage)..load();
    final loot = LootCubit(storage: storage)..load();
    addTearDown(engagement.close);
    addTearDown(loot.close);
    final sessions = GameSessionFactory(
      storage: storage,
      engagement: engagement,
      loot: loot,
      todayProvider: () => '2026-07-18',
    );

    await tester.pumpWidget(MaterialApp(
      home: TierSelectScreen(
        storage: storage,
        adService: AdService(),
        engagement: engagement,
        loot: loot,
        sessions: sessions,
        todayProvider: () => '2026-07-18',
      ),
    ));

    await tester.tap(find.byKey(const Key('tier-easy')));
    await tester.pumpAndSettle();

    expect(find.byType(GameScreen), findsOneWidget);
    expect(find.byKey(const Key('undo-button')), findsOneWidget);

    Navigator.of(tester.element(find.byType(GameScreen))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(GameScreen), findsNothing);
  });
}
