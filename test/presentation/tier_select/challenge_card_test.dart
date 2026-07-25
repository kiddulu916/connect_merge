import 'package:connect_merge/presentation/screens/tier_select/challenge_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatCountdown', () {
    test('pads to HH:MM:SS', () {
      expect(formatCountdown(const Duration(seconds: 5)), '00:00:05');
      expect(formatCountdown(const Duration(hours: 1, minutes: 2, seconds: 3)),
          '01:02:03');
      expect(formatCountdown(const Duration(hours: 25)), '25:00:00');
    });
  });

  group('ChallengeCard', () {
    testWidgets('locked state shows the lock icon, teaser, and countdown',
        (tester) async {
      var played = false;
      await tester.pumpWidget(MaterialApp(
        home: ChallengeCard(
          unlocked: false,
          completed: false,
          ruleName: 'Long Chains Only',
          timeUntilUnlock: const Duration(hours: 3, minutes: 15, seconds: 2),
          onPlay: () => played = true,
        ),
      ));

      expect(find.byIcon(Icons.lock_clock), findsOneWidget);
      expect(find.text('Daily Challenge'), findsOneWidget);
      expect(find.text('Today: Long Chains Only'), findsOneWidget);
      expect(find.text('Opens in 03:15:02'), findsOneWidget);
      expect(find.byKey(const Key('play-challenge')), findsNothing);

      // Locked: tapping the card does nothing.
      await tester.tap(find.byKey(const Key('tier-challenge')));
      await tester.pump();
      expect(played, isFalse);
    });

    testWidgets(
        'unlocked + not played shows the bolt icon and a working Play button',
        (tester) async {
      var played = false;
      await tester.pumpWidget(MaterialApp(
        home: ChallengeCard(
          unlocked: true,
          completed: false,
          ruleName: 'Combo Rush',
          timeUntilUnlock: Duration.zero,
          onPlay: () => played = true,
        ),
      ));

      expect(find.byIcon(Icons.bolt), findsOneWidget);
      expect(find.text('Today: Combo Rush'), findsOneWidget);
      expect(find.text('Play'), findsOneWidget);
      expect(find.textContaining('Opens in'), findsNothing);

      await tester.tap(find.byKey(const Key('play-challenge')));
      await tester.pump();
      expect(played, isTrue);

      // Tapping the card body also plays (whole card is tappable when live).
      played = false;
      await tester.tap(find.byKey(const Key('tier-challenge')));
      await tester.pump();
      expect(played, isTrue);
    });

    testWidgets('completed state shows the check icon and is not tappable',
        (tester) async {
      var played = false;
      await tester.pumpWidget(MaterialApp(
        home: ChallengeCard(
          unlocked: true,
          completed: true,
          ruleName: 'Dense Start',
          timeUntilUnlock: Duration.zero,
          onPlay: () => played = true,
        ),
      ));

      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.text('Done today ✓  ·  Dense Start'), findsOneWidget);
      expect(find.byKey(const Key('play-challenge')), findsNothing);

      await tester.tap(find.byKey(const Key('tier-challenge')));
      await tester.pump();
      expect(played, isFalse);
    });
  });
}
