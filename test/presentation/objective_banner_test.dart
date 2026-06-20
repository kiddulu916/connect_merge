import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:merge_count/domain/models/daily_objective.dart';
import 'package:merge_count/presentation/widgets/objective_banner.dart';

void main() {
  testWidgets('shows label and progress, and a done state when met',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ObjectiveBanner(
          objective: DailyObjective(kind: ObjectiveKind.chainLength, target: 5),
          progress: 3,
        ),
      ),
    ));
    expect(find.textContaining('Land a 5-chain'), findsOneWidget);
    expect(find.textContaining('3/5'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ObjectiveBanner(
          objective: DailyObjective(kind: ObjectiveKind.chainLength, target: 5),
          progress: 5,
        ),
      ),
    ));
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });
}
