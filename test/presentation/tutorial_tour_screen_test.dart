import 'dart:async';

import 'package:connect_merge/domain/engine/game_engine.dart';
import 'package:connect_merge/domain/engine/prng.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/game_status.dart';
import 'package:connect_merge/presentation/screens/tutorial_tour_screen.dart';
import 'package:connect_merge/presentation/widgets/board_widget.dart';
import 'package:connect_merge/presentation/widgets/tutorial_spotlight.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

const _mergeAction = CustomSemanticsAction(label: 'Merge highlighted tiles');

Future<void> _pumpTour(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: TutorialTourScreen(
        onSkip: (_) async => true,
      ),
    ),
  );
  await tester.pump();
}

void _performMergeAction(WidgetTester tester) {
  final node = tester.getSemantics(
    find.byKey(const Key('tutorial-semantic-merge')),
  );
  node.owner!.performAction(
    node.id,
    SemanticsAction.customAction,
    CustomSemanticsAction.getIdentifier(_mergeAction),
  );
}

void main() {
  testWidgets('spotlight passes taps only through its interactive cutout',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => taps += 1,
                ),
              ),
              TutorialSpotlight(
                targetRect: const Rect.fromLTWH(50, 100, 100, 100),
                stepLabel: 'test-step',
                title: 'Test',
                body: 'Test body',
                onSkip: () {},
                onNext: null,
                allowTargetInteraction: true,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tapAt(const Offset(75, 125));
    await tester.tapAt(const Offset(25, 250));

    expect(taps, 1);
  });

  test('deadlock fixture has one merge and its pinned refill ends the run', () {
    expect(_mergeableEdges(tutorialDeadlockBoard), 1);
    expect(
      GameEngine.isValidChain(
        tutorialDeadlockBoard,
        tutorialDeadlockPath.reversed.toList(),
      ),
      isFalse,
    );
    var board =
        GameEngine.collapseChain(tutorialDeadlockBoard, tutorialDeadlockPath);
    final landing = Prng(tutorialDeadlockSeed);
    for (final tier in tutorialDeadlockDropTiers) {
      board = GameEngine.applyDrop(board, tier, landing);
    }
    board = GameEngine.evaluateStatus(board);

    expect(board.status, GameStatus.deadlocked);
    expect(GameEngine.hasMergeAvailable(board), isFalse);
  });

  testWidgets('step 1 real board drag advances to the moves lesson',
      (tester) async {
    await _pumpTour(tester);

    final rect = tester.getRect(find.byType(BoardWidget));
    const gap = 8.0;
    final cell = (rect.width - gap * 5) / 4;
    final first = rect.topLeft +
        Offset(gap + (cell + gap) + cell / 2, gap + (cell + gap) + cell / 2);
    final second = first + Offset(cell + gap, 0);
    final gesture = await tester.startGesture(first);
    await gesture.moveTo(second, timeStamp: const Duration(milliseconds: 150));
    await gesture.up();
    await tester.pump();

    expect(find.text('30 moves a day'), findsOneWidget);
  });

  testWidgets('semantic merge actions complete steps 1 and 5', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpTour(tester);

    _performMergeAction(tester);
    await tester.pump();
    expect(find.text('30 moves a day'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tutorial-next'))); // drops
    await tester.pump();
    await tester.tap(find.byKey(const Key('tutorial-next'))); // chain rule
    await tester.pump();
    await tester.tap(find.byKey(const Key('tutorial-next'))); // deadlock
    await tester.pump();
    expect(find.text('Avoid a deadlock'), findsOneWidget);

    _performMergeAction(tester);
    await tester.pump(const Duration(milliseconds: 500));

    final board = tester.widget<BoardWidget>(find.byType(BoardWidget)).board;
    expect(board.status, GameStatus.deadlocked);
    expect(GameEngine.hasMergeAvailable(board), isFalse);
    expect(find.text('No moves left'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('Skip is available throughout the scripted route',
      (tester) async {
    await _pumpTour(tester);
    expect(find.byKey(const Key('tutorial-skip')), findsOneWidget);

    final semantics = tester.ensureSemantics();
    _performMergeAction(tester);
    await tester.pump();
    await tester.tap(find.byKey(const Key('tutorial-next')));
    await tester.pump();
    expect(find.byKey(const Key('tutorial-skip')), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('Skip cancels a pending deadlock refill immediately',
      (tester) async {
    final skipResult = Completer<bool>();
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: TutorialTourScreen(
        onSkip: (_) => skipResult.future,
      ),
    ));
    _performMergeAction(tester);
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const Key('tutorial-next')));
      await tester.pump();
    }

    _performMergeAction(tester);
    await tester.pump();
    await tester.tap(find.byKey(const Key('tutorial-skip')));
    await tester.pump(const Duration(milliseconds: 200));

    final board = tester.widget<BoardWidget>(find.byType(BoardWidget)).board;
    expect(board.emptyIndices, hasLength(1));
    expect(find.byKey(const Key('tutorial-completing')), findsOneWidget);

    skipResult.complete(false);
    await tester.pump();
    semantics.dispose();
  });
}

int _mergeableEdges(BoardState board) {
  var count = 0;
  for (var index = 0; index < board.cells.length; index++) {
    final row = index ~/ board.gridSize;
    final column = index % board.gridSize;
    for (final neighbor in [
      if (column + 1 < board.gridSize) index + 1,
      if (row + 1 < board.gridSize) index + board.gridSize,
    ]) {
      if (GameEngine.isValidChain(board, [index, neighbor]) ||
          GameEngine.isValidChain(board, [neighbor, index])) {
        count++;
      }
    }
  }
  return count;
}
