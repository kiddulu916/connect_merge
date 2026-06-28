import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/models/tile.dart';
import 'package:connect_merge/presentation/widgets/grid_cell_widget.dart';

void main() {
  testWidgets('renders the tile value 2^tier', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: GridCellWidget(tile: Tile(id: 1, tier: 5), size: 60),
      ),
    ));
    expect(find.text('32'), findsOneWidget); // 2^5
  });

  testWidgets('empty cell renders no value text', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: GridCellWidget(tile: null, size: 60)),
    ));
    expect(find.byType(Text), findsNothing);
  });
}
