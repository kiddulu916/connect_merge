import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/constants.dart';
import '../../domain/engine/game_engine.dart';
import '../../domain/engine/prng.dart';
import '../../domain/models/board_state.dart';
import '../../domain/models/game_status.dart';
import '../../domain/models/tile.dart';
import '../theme/tokens.dart';
import '../widgets/board_widget.dart';
import '../widgets/moves_counter.dart';
import '../widgets/tutorial_spotlight.dart';

const tutorialDeadlockPath = <int>[0, 1];
const tutorialDeadlockSeed = 0x5EED;
const tutorialDeadlockDropTiers = <int>[5];

enum TutorialTourResult { completed, skipped }

final tutorialDeadlockBoard = _board(const [
  1,
  2,
  5,
  1,
  3,
  5,
  1,
  3,
  5,
  1,
  3,
  5,
  1,
  3,
  5,
  1,
]);

/// Scripted, non-submitting mechanics portion of the first-launch tour.
class TutorialTourScreen extends StatefulWidget {
  final Future<bool> Function(int step) onSkip;

  const TutorialTourScreen({
    super.key,
    required this.onSkip,
  });

  @override
  State<TutorialTourScreen> createState() => _TutorialTourScreenState();
}

class _TutorialTourScreenState extends State<TutorialTourScreen> {
  final _boardKey = GlobalKey();
  final _movesKey = GlobalKey();
  int _step = 1;
  late BoardState _board = _fixtureFor(1);
  Rect? _targetRect;
  Timer? _refillTimer;
  int _dropCursor = 0;
  bool _deadlocked = false;
  bool _completing = false;
  bool _retryCompletion = false;
  bool _allowPop = false;

  static const _stepOnePath = <int>[5, 6];
  static const _stepFourPath = <int>[5, 6, 7];

  @override
  void initState() {
    super.initState();
    _measureAfterLayout();
  }

  @override
  void dispose() {
    _refillTimer?.cancel();
    super.dispose();
  }

  void _measureAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target =
          _step == 2 ? _movesKey.currentContext : _boardKey.currentContext;
      final box = target?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final origin = box.localToGlobal(Offset.zero);
      final rect = switch (_step) {
        1 => _pathRect(origin, box.size, _stepOnePath),
        4 => _pathRect(origin, box.size, _stepFourPath),
        5 => _pathRect(origin, box.size, tutorialDeadlockPath),
        _ => origin & box.size,
      };
      if (rect != _targetRect) setState(() => _targetRect = rect);
    });
  }

  Rect _pathRect(Offset origin, Size size, List<int> path) {
    const gap = 8.0;
    final cell = (size.width - gap * 5) / 4;
    Rect? result;
    for (final index in path) {
      final row = index ~/ 4;
      final column = index % 4;
      final rect = Rect.fromLTWH(
        origin.dx + gap + column * (cell + gap),
        origin.dy + gap + row * (cell + gap),
        cell,
        cell,
      );
      result = result == null ? rect : result.expandToInclude(rect);
    }
    return result!;
  }

  void _showStep(int step) {
    _refillTimer?.cancel();
    setState(() {
      _step = step;
      _board = _fixtureFor(step);
      _targetRect = null;
      _deadlocked = false;
      _dropCursor = 0;
    });
    _measureAfterLayout();
  }

  void _handleChain(List<int> path) {
    if ((_step != 1 && _step != 5) || !GameEngine.isValidChain(_board, path)) {
      return;
    }
    final expected = _step == 1 ? _stepOnePath : tutorialDeadlockPath;
    final reverseStepOne =
        _step == 1 && _samePath(path, expected.reversed.toList());
    if (!_samePath(path, expected) && !reverseStepOne) return;
    final collapsed = GameEngine.collapseChain(_board, path);
    if (_step == 1) {
      _showStep(2);
      return;
    }
    setState(() => _board = collapsed);
    _scheduleNextDrop();
  }

  void _scheduleNextDrop() {
    _refillTimer?.cancel();
    _refillTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted || _step != 5) return;
      var board = _board;
      if (_dropCursor < tutorialDeadlockDropTiers.length) {
        final landing = Prng(tutorialDeadlockSeed);
        for (var i = 0; i < _dropCursor; i++) {
          landing.nextInt(1);
        }
        board = GameEngine.applyDrop(
          board,
          tutorialDeadlockDropTiers[_dropCursor],
          landing,
        );
        _dropCursor++;
      }
      final finished = _dropCursor == tutorialDeadlockDropTiers.length;
      setState(() {
        _board = finished ? GameEngine.evaluateStatus(board) : board;
        _deadlocked = finished && _board.status == GameStatus.deadlocked;
      });
      if (!finished) _scheduleNextDrop();
    });
  }

  void _semanticMerge() {
    _handleChain(_step == 1 ? _stepOnePath : tutorialDeadlockPath);
  }

  Future<void> _requestSkip() async {
    if (_completing) return;
    _refillTimer?.cancel();
    setState(() {
      _completing = true;
      _retryCompletion = false;
    });
    final success = await widget.onSkip(_step);
    if (!mounted) return;
    if (success) {
      _popWith(TutorialTourResult.skipped);
      return;
    }
    setState(() {
      _completing = false;
      _retryCompletion = true;
    });
  }

  void _popWith(TutorialTourResult result) {
    if (_allowPop) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(result);
    });
  }

  @override
  Widget build(BuildContext context) {
    final copy = _copyForStep();
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestSkip();
      },
      child: Scaffold(
        key: const Key('tutorial-tour'),
        backgroundColor: AppColors.background,
        body: Stack(
          children: [
            ExcludeSemantics(
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 220),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Learn Connect Merge',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 12),
                      KeyedSubtree(
                        key: _movesKey,
                        child: MovesCounter(
                          movesRemaining: kMovesPerDay,
                          score: _board.score,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Center(
                          child: AspectRatio(
                            aspectRatio: 1,
                            child: KeyedSubtree(
                              key: _boardKey,
                              child: BoardWidget(
                                key: const Key('tutorial-board'),
                                board: _board,
                                onChain: _handleChain,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: TutorialSpotlight(
                key: _completing ? const Key('tutorial-completing') : null,
                targetRect: _targetRect,
                stepLabel: 'step-$_step',
                title: _deadlocked ? 'No moves left' : copy.$1,
                body: _deadlocked
                    ? 'That last merge left no adjacent equal-or-ascending pair. '
                        'A real daily run ends here.'
                    : copy.$2,
                onSkip: _requestSkip,
                onNext: switch (_step) {
                  _ when _retryCompletion => _requestSkip,
                  2 => () => _showStep(3),
                  3 => () => _showStep(4),
                  4 => () => _showStep(5),
                  5 when _deadlocked => () {
                      _popWith(TutorialTourResult.completed);
                    },
                  _ => null,
                },
                nextLabel: _retryCompletion
                    ? 'Retry'
                    : _step == 5
                        ? 'Continue'
                        : 'Next',
                nextKey: _retryCompletion
                    ? const Key('tutorial-retry')
                    : const Key('tutorial-next'),
                onSemanticMerge: (_step == 1 || (_step == 5 && !_deadlocked))
                    ? _semanticMerge
                    : null,
                allowTargetInteraction:
                    _step == 1 || (_step == 5 && !_deadlocked),
                waiting: _completing,
              ),
            ),
          ],
        ),
      ),
    );
  }

  (String, String) _copyForStep() => switch (_step) {
        1 => (
            'Merge anywhere',
            'Drag across the two highlighted equal tiles. Connected tiles can '
                'merge anywhere on the board.',
          ),
        2 => (
            '$kMovesPerDay moves a day',
            'Every successful daily chain spends one move. Build the best score '
                'you can before this fixed budget runs out.',
          ),
        3 => (
            'New tiles drop in',
            'After every merge, empty cells refill. Early drops stay low; the '
                'possible drop tiers widen as the run progresses.',
          ),
        4 => (
            'Equal or one tier up',
            'A chain may stay level or rise exactly one tier at a time. It can '
                'never go down or skip a tier.',
          ),
        _ => (
            'Avoid a deadlock',
            'This board has one legal merge left. Drag the lower tile into the '
                'higher tile, then watch why preserving another pair matters.',
          ),
      };
}

bool _samePath(List<int> actual, List<int> expected) {
  if (actual.length != expected.length) return false;
  for (var i = 0; i < actual.length; i++) {
    if (actual[i] != expected[i]) return false;
  }
  return true;
}

BoardState _fixtureFor(int step) => switch (step) {
      1 => _board(const [
          3,
          null,
          5,
          null,
          null,
          1,
          1,
          null,
          5,
          null,
          3,
          null,
          null,
          5,
          null,
          3,
        ]),
      4 => _board(const [
          5,
          null,
          1,
          null,
          null,
          2,
          2,
          3,
          5,
          null,
          1,
          null,
          null,
          5,
          null,
          3,
        ]),
      5 => tutorialDeadlockBoard,
      _ => _board(const [
          1,
          null,
          3,
          null,
          null,
          3,
          null,
          5,
          5,
          null,
          1,
          null,
          null,
          1,
          null,
          3,
        ]),
    };

BoardState _board(List<int?> tiers) {
  var id = 0;
  return BoardState(
    cells: [
      for (final tier in tiers)
        if (tier == null) null else Tile(id: id++, tier: tier),
    ],
    movesRemaining: kMovesPerDay,
    score: 0,
    nextTileId: id,
    dropIndex: 0,
    adContinuesUsed: 0,
    movesMade: 0,
    status: GameStatus.playing,
    gridSize: 4,
  );
}
