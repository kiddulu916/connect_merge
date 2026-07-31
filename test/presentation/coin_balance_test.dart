import 'package:connect_merge/presentation/widgets/coin_balance.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  int shownValue(WidgetTester tester) {
    final text = tester.widget<Text>(find.descendant(
      of: find.byType(CoinBalance),
      matching: find.byType(Text),
    ));
    return int.parse(text.data!);
  }

  testWidgets('CoinBalance renders statically, then counts up on a change',
      (tester) async {
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: CoinBalance(coins: 100))));
    // First render is static (no count-up from 0).
    expect(shownValue(tester), 100);

    // Balance increases (e.g. returning from a run that earned coins).
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: CoinBalance(coins: 160))));
    await tester.pump(); // kick off the animation
    await tester.pump(const Duration(milliseconds: 250));

    // Mid-animation: strictly between the old and new totals.
    final mid = shownValue(tester);
    expect(mid, greaterThan(100));
    expect(mid, lessThan(160));

    await tester.pumpAndSettle();
    expect(shownValue(tester), 160);
  });

  testWidgets('CoinBalance replays a count-up from animateFrom on first build',
      (tester) async {
    // Models returning to tier-select: the balance is already 500, but we want
    // it to visibly tally up from the pre-run 400.
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: CoinBalance(key: ValueKey(1), coins: 500, animateFrom: 400),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    final mid = shownValue(tester);
    expect(mid, greaterThan(400));
    expect(mid, lessThan(500));

    await tester.pumpAndSettle();
    expect(shownValue(tester), 500);
  });
}
