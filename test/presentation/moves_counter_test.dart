import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/presentation/widgets/moves_counter.dart';

void main() {
  testWidgets('shows moves remaining and score', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: MovesCounter(movesRemaining: 12, score: 256)),
    ));
    expect(find.text('12'), findsOneWidget);
    expect(find.text('256'), findsOneWidget);
  });
}
