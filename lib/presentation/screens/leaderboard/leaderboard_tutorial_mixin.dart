import 'package:flutter/material.dart';

import '../../../domain/models/difficulty.dart';
import '../../widgets/tutorial_spotlight.dart';
import '../leaderboard_screen.dart' show LeaderboardScreen;

/// Which control the first-launch tour (step 7) spotlights next on
/// [LeaderboardScreen]: the Global/Friends toggle, the period tabs, or the
/// first leaderboard row.
enum TutorialTarget { scope, period, row }

/// Drives the step-7 tutorial spotlight sequence over [LeaderboardScreen]'s
/// scope toggle, period tabs, and first row. Split out of
/// `_LeaderboardScreenState` — leaderboard_screen.dart's build() reads
/// [currentTutorialTarget], [tutorialRect], [tutorialAdvancing], [allowPop],
/// and [isRowFallback], and calls [tutorialCopy], [nextTutorialTarget],
/// [finishTutorial], and [setRowsAvailable].
mixin LeaderboardTutorialMixin on State<LeaderboardScreen> {
  final scopeTutorialKey = GlobalKey();
  final periodTutorialKey = GlobalKey();
  final rowTutorialKey = GlobalKey();

  int _tutorialTargetIndex = 0;
  Rect? tutorialRect;
  bool? _rowsAvailable;
  bool _rowFallbackLocked = false;
  bool tutorialAdvancing = true;
  bool allowPop = false;

  List<TutorialTarget> get _tutorialTargets => [
        if (widget.friendsService != null) TutorialTarget.scope,
        if (widget.initialDifficulty != Difficulty.challenge)
          TutorialTarget.period,
        TutorialTarget.row,
      ];

  TutorialTarget get currentTutorialTarget =>
      _tutorialTargets[_tutorialTargetIndex];

  bool get isRowFallback =>
      currentTutorialTarget == TutorialTarget.row &&
      (_rowFallbackLocked || _rowsAvailable != true);

  /// Call from [State.initState] when `widget.tutorialMode` is true.
  void initTutorial() {
    if (_tutorialTargets.first == TutorialTarget.row) {
      _rowFallbackLocked = true;
    }
    _measureTutorialTarget();
  }

  void _measureTutorialTarget() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.tutorialMode) return;
      final target = currentTutorialTarget;
      final context = switch (target) {
        TutorialTarget.scope => scopeTutorialKey.currentContext,
        TutorialTarget.period => periodTutorialKey.currentContext,
        TutorialTarget.row => !_rowFallbackLocked && _rowsAvailable == true
            ? rowTutorialKey.currentContext
            : null,
      };
      final box = context?.findRenderObject() as RenderBox?;
      final rect = box == null || !box.hasSize
          ? null
          : box.localToGlobal(Offset.zero) & box.size;
      if (tutorialRect != rect || tutorialAdvancing) {
        setState(() {
          tutorialRect = rect;
          tutorialAdvancing = false;
        });
      }
    });
  }

  void setRowsAvailable(bool available) {
    if (_rowsAvailable == available) return;
    setState(() => _rowsAvailable = available);
    _measureTutorialTarget();
  }

  void nextTutorialTarget() {
    if (tutorialAdvancing || allowPop) return;
    if (_tutorialTargetIndex == _tutorialTargets.length - 1) {
      finishTutorial(TutorialResult.completed);
      return;
    }
    setState(() {
      tutorialAdvancing = true;
      _tutorialTargetIndex++;
      tutorialRect = null;
      if (_tutorialTargets[_tutorialTargetIndex] == TutorialTarget.row &&
          _rowsAvailable != true) {
        _rowFallbackLocked = true;
      }
    });
    _measureTutorialTarget();
  }

  void finishTutorial(TutorialResult result) {
    if (allowPop) return;
    setState(() => allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(result);
    });
  }

  (String, String) tutorialCopy(TutorialTarget target) => switch (target) {
        TutorialTarget.scope => (
            'Global or friends',
            'Compare with everyone, or switch to Friends for a smaller race.',
          ),
        TutorialTarget.period => (
            'Choose a time period',
            'Daily ranks your best score for today. Weekly, Monthly, and '
                'All-time each sum your best score from every day in that '
                'span, so playing well on more days climbs you higher — not '
                'just one great run.',
          ),
        TutorialTarget.row => (
            'How rankings work',
            'Each row shows a rank and best score, with your own row marked '
                'You once the board has entries.',
          ),
      };
}
