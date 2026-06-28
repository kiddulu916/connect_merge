import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/presentation/widgets/drop_queue_rail.dart';

void main() {
  testWidgets('renders one chip per upcoming tier with its value', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: DropQueueRail(tiers: [1, 2, 3])),
    ));
    expect(find.text('2'), findsOneWidget); // 2^1
    expect(find.text('4'), findsOneWidget); // 2^2
    expect(find.text('8'), findsOneWidget); // 2^3
    expect(find.textContaining('NEXT'), findsOneWidget);
  });
}
