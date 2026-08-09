import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/application/game_cubit.dart';
import 'package:connect_merge/domain/engine/daily_seeder.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/game_status.dart';
import 'package:connect_merge/infrastructure/ad_service.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:connect_merge/presentation/screens/game_screen.dart';

const _date = '2026-07-18';
const _difficulty = Difficulty.easy;

// Copied verbatim from test/application/game_cubit_submission_test.dart's
// existing private helper (test-file-private in Dart — cannot be imported
// across files, so this is intentional duplication, not drift risk, as long
// as it's kept byte-identical to the source).
//
// Deliberately the continue-eligible variant, not the terminal one: a
// terminal board (adContinuesUsed maxed) is auto-submitted by GameCubit.init
// itself (see game_cubit_submission_test.dart's "resume retries pending and
// terminal none" case), which would make this test pass even without the
// PopScope fix under test. The continue-eligible + SubmitStatus.none
// combination is exactly the gap this task closes: resume deliberately does
// NOT auto-submit it (see that same file's "...but not continue-eligible
// none" case), so only the hardware-back PopScope handler can be the one
// calling submitIfPending here.
BoardState _continueEligibleBoard() =>
    const DailySeeder(_date, _difficulty).generate().board.copyWith(
          movesRemaining: 0,
          status: GameStatus.outOfMoves,
        );

Future<void> _saveCompleted(StorageService storage, BoardState board) async {
  await storage.saveSnapshot(GameSnapshot(
    date: _date,
    difficulty: _difficulty,
    board: board,
    completed: true,
  ));
}

void main() {
  testWidgets(
      'hardware/system back on the result screen triggers submitIfPending',
      (tester) async {
    final storage = InMemoryStorageService();
    await _saveCompleted(storage, _continueEligibleBoard());
    final calls = <String>[];
    final cubit = GameCubit(
      storage: storage,
      todayProvider: () => _date,
      onSubmitRun: ({
        required date,
        required difficulty,
        required moveLog,
        required adContinues,
      }) async {
        calls.add('submitted');
        return SubmitOutcome.success;
      },
    );
    await cubit.init(difficulty: _difficulty);

    // GameScreen is always reached via Navigator.push in production (see
    // tier_select_screen.dart's _startTier), never as a route's sole/root
    // widget — PopScope.onPopInvokedWithResult only fires when there is an
    // actual route beneath to reveal, so the test must push it the same way
    // for the simulated hardware back to exercise the handler at all.
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigatorKey,
      home: const Scaffold(body: SizedBox.shrink()),
    ));
    navigatorKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => BlocProvider<GameCubit>.value(
        value: cubit,
        child: GameScreen(
          adService: AdService.withSeams(),
          storage: storage,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Simulate the system/hardware back gesture (Android back button,
    // iOS edge swipe) rather than tapping the in-app Main Menu button.
    final dynamic widgetsAppState =
        tester.state(find.byType(WidgetsApp));
    await widgetsAppState.didPopRoute();
    await tester.pumpAndSettle();

    expect(calls, ['submitted']);
    expect(storage.loadSubmitStatus(_date, _difficulty).status,
        SubmitStatus.settled);
    await cubit.close();
  });
}
