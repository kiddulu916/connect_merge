import 'package:flutter/material.dart';

import '../../../application/engagement_cubit.dart';
import '../../../domain/models/difficulty.dart';
import '../../widgets/tutorial_spotlight.dart';
import '../leaderboard_screen.dart';
import '../tier_select_screen.dart';
import '../tutorial_tour_screen.dart';

enum TourPhase { inactive, mechanics, tiers, leaderboard }

/// Step 6 of the tour is two beats, not one pass per tier: spotlight every
/// difficulty at once with a single blanket description, then spotlight one
/// representative practice icon with a single blanket explanation.
enum _TierTourStep { allTiers, practice }

/// Tutorial-tour orchestration for [TierSelectScreen]: the guided-mechanics ->
/// tier-spotlight -> leaderboard-spotlight flow that runs on first launch.
///
/// The host [State] owns the `tierListKey`/`practiceTourKeys` GlobalKeys (used
/// elsewhere to build the tier list) and the `engagementCubit` (used elsewhere
/// for engagement state) — this mixin only reads them via the abstract
/// getters below.
mixin TierTourMixin on State<TierSelectScreen> {
  static const _tierTourSteps = [
    _TierTourStep.allTiers,
    _TierTourStep.practice,
  ];

  /// Tier-list scroll anchor, owned by the host state (also used to build the
  /// tier list itself).
  GlobalKey get tierListKey;

  /// Per-difficulty practice-icon anchors, owned by the host state (also used
  /// to build the tier list itself).
  Map<Difficulty, GlobalKey> get practiceTourKeys;

  /// Engagement cubit, owned by the host state.
  EngagementCubit get engagementCubit;

  TourPhase tourPhase = TourPhase.inactive;
  int _tierTourIndex = 0;
  Rect? tourTargetRect;
  bool _tierTourAdvancing = false;
  bool completing = false;
  bool completionFailed = false;
  bool _completionPending = false;
  bool _pendingSkipped = false;
  int _pendingCompletionStep = 1;

  bool get tourActive => tourPhase != TourPhase.inactive;

  void launchMechanics() {
    if (!mounted || tourPhase != TourPhase.mechanics) return;
    Navigator.of(context)
        .push<TutorialResult>(
      MaterialPageRoute<TutorialResult>(
        builder: (_) => TutorialTourScreen(
          onSkip: (step) => completeTour(skipped: true, step: step),
        ),
      ),
    )
        .then((result) {
      if (mounted && result == TutorialResult.completed) _startTierTour();
    });
  }

  void _startTierTour() {
    if (!mounted) return;
    setState(() {
      tourPhase = TourPhase.tiers;
      _tierTourIndex = 0;
      tourTargetRect = null;
      _tierTourAdvancing = true;
    });
    _measureTierTourTarget();
  }

  GlobalKey get _currentTierTourKey => switch (_tierTourSteps[_tierTourIndex]) {
        _TierTourStep.allTiers => tierListKey,
        _TierTourStep.practice => practiceTourKeys[Difficulty.easy]!,
      };

  Future<void> _measureTierTourTarget([int attempt = 0]) async {
    final targetIndex = _tierTourIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted ||
          tourPhase != TourPhase.tiers ||
          _tierTourIndex != targetIndex) {
        return;
      }
      final targetContext = _currentTierTourKey.currentContext;
      if (targetContext == null) {
        if (attempt < 3) {
          _measureTierTourTarget(attempt + 1);
        } else {
          setState(() => _tierTourAdvancing = false);
        }
        return;
      }
      if (!targetContext.mounted) return;
      await Scrollable.ensureVisible(
        targetContext,
        alignment: 0.45,
        duration: const Duration(milliseconds: 180),
      );
      if (!mounted ||
          !targetContext.mounted ||
          tourPhase != TourPhase.tiers ||
          _tierTourIndex != targetIndex) {
        return;
      }
      final box = targetContext.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      setState(() {
        tourTargetRect = rect;
        _tierTourAdvancing = false;
      });
    });
  }

  void _nextTierTourTarget() {
    if (_tierTourAdvancing || tourTargetRect == null) return;
    _tierTourAdvancing = true;
    if (_tierTourIndex < _tierTourSteps.length - 1) {
      setState(() {
        _tierTourIndex++;
        tourTargetRect = null;
      });
      _measureTierTourTarget();
      return;
    }
    _launchLeaderboardTutorial();
  }

  void _launchLeaderboardTutorial() {
    setState(() {
      tourPhase = TourPhase.leaderboard;
      tourTargetRect = null;
    });
    final service = widget.leaderboard;
    if (service == null) return;
    Navigator.of(context)
        .push<TutorialResult>(
            MaterialPageRoute<TutorialResult>(
      builder: (_) => LeaderboardScreen(
        service: service,
        friendsService: widget.friends,
        initialDifficulty: Difficulty.easy,
        todayProvider: widget.todayProvider,
        weeklyPrizes: engagementCubit.state.weeklyPrizes,
        tutorialMode: true,
      ),
    ))
        .then((result) {
      if (!mounted) return;
      completeTour(
        skipped: result != TutorialResult.completed,
        step: 7,
      );
    });
  }

  Future<bool> completeTour({required bool skipped, required int step}) async {
    if (completing) return false;
    if (!_completionPending) {
      _completionPending = true;
      _pendingSkipped = skipped;
      _pendingCompletionStep = step;
      if (skipped) {
        widget.analytics?.logEvent('tutorial_skipped', {'step': step});
      }
    }
    setState(() {
      completing = true;
      completionFailed = false;
    });
    final success = await engagementCubit.markTutorialSeen();
    if (!mounted) return success;
    if (!success) {
      setState(() {
        completing = false;
        completionFailed = true;
      });
      return false;
    }
    widget.analytics?.logEvent('tutorial_completed');
    setState(() {
      tourPhase = TourPhase.inactive;
      completing = false;
      completionFailed = false;
      _completionPending = false;
    });
    return true;
  }

  void _retryTourCompletion() {
    completeTour(
      skipped: _pendingSkipped,
      step: _pendingCompletionStep,
    );
  }

  (String, String) get _tierTourCopy =>
      switch (_tierTourSteps[_tierTourIndex]) {
        _TierTourStep.allTiers => (
            'Choose your difficulty',
            'Easy (8×8) is the most forgiving board. Medium, Hard, and '
                'Legendary shrink the grid and starting tiles for a tighter '
                'puzzle each step up. Challenge uses the tightest board plus '
                'a daily rule and unlocks at noon UTC on its own leaderboard. '
                'You get one run a day per difficulty, so make it count for '
                'your best score.',
          ),
        _TierTourStep.practice => (
            'Practice mode',
            'Tap the practice icon on any tier to play that board '
                'off-leaderboard, anytime, with no daily move budget — a good '
                'way to warm up before your one daily run.',
          ),
      };

  Widget buildTourOverlay() {
    final isTier = tourPhase == TourPhase.tiers;
    final copy = isTier
        ? _tierTourCopy
        : (
            'Leaderboards',
            'Global rankings compare daily scores by difficulty and period. '
                'Connect online to see the live board and friends results.',
          );
    return TutorialSpotlight(
      key: completing ? const Key('tutorial-completing') : null,
      targetRect: isTier ? tourTargetRect : null,
      stepLabel: isTier ? 'step-6' : 'step-7',
      title: completionFailed ? 'Couldn’t save progress' : copy.$1,
      body: completionFailed
          ? 'Your tour is still open. Check local storage and try again.'
          : copy.$2,
      onSkip: () => completeTour(step: isTier ? 6 : 7, skipped: true),
      onNext: completionFailed
          ? _retryTourCompletion
          : isTier
              ? _tierTourAdvancing || tourTargetRect == null
                  ? null
                  : _nextTierTourTarget
              : () => completeTour(step: 7, skipped: false),
      nextLabel: completionFailed
          ? 'Retry'
          : isTier
              ? 'Next'
              : 'Finish',
      nextKey: completionFailed
          ? const Key('tutorial-retry')
          : const Key('tutorial-next'),
      waiting: completing,
    );
  }
}
