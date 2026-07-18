import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../application/engagement_cubit.dart';
import '../../application/game_cubit.dart';
import '../../application/game_state.dart';
import '../../domain/engine/near_miss.dart';
import '../../domain/models/board_state.dart';
import '../../domain/models/challenge_rule.dart';
import '../../domain/models/cosmetic.dart';
import '../../domain/models/player_level.dart';
import '../../infrastructure/storage_service.dart';
import '../../domain/models/difficulty.dart';
import '../../infrastructure/ad_service.dart';
import '../../infrastructure/notification_service.dart';
import '../widgets/banner_slot.dart';
import '../widgets/board_widget.dart';
import '../widgets/drop_queue_rail.dart';
import '../widgets/hint_button.dart';
import '../widgets/moves_counter.dart';
import '../widgets/objective_banner.dart';
import '../widgets/rewarded_dialog.dart';
import '../theme/tokens.dart';
import '../widgets/streak_banner.dart';
import 'score_share_screen.dart';
import 'stats_calendar_screen.dart';
import 'tutorial_overlay.dart';

class GameScreen extends StatefulWidget {
  final AdService adService;

  /// Storage, so the screen can gate the first-run tutorial (`tutorialSeen`),
  /// read the `colorblindMode` setting, and load the day-result history for the
  /// stats calendar (Phase 4). Required.
  final StorageService storage;

  /// Phase 4 engagement state (streak banner, cosmetic, newly-unlocked badges).
  final EngagementCubit? engagement;

  /// Unused directly here today (rescheduling happens on return to tier select)
  /// but accepted for symmetry / future use.
  final NotificationService? notifications;

  /// The player's friend code, when online. Passed to [ScoreShareScreen] so the
  /// share card carries an invite link and the "Invite a friend" CTA appears.
  final String? friendCode;

  const GameScreen({
    super.key,
    required this.adService,
    required this.storage,
    this.engagement,
    this.notifications,
    this.friendCode,
  });

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  /// Last revealed next-drop tier (null until a hint is used). Read-only display.
  int? _hintTier;

  /// Whether the first-run tutorial overlay is currently showing. Set on init
  /// from the persisted `tutorialSeen` flag; cleared (and persisted) on dismiss.
  bool _showTutorial = false;

  /// Cached colorblind-mode setting (Phase 4). Read once from the profile; drives
  /// the per-tier pattern overlay on the board.
  bool _colorblind = false;

  AdService get adService => widget.adService;
  String? get friendCode => widget.friendCode;

  Cosmetic get _cosmetic =>
      widget.engagement?.state.selectedCosmetic ?? Cosmetic.classic;

  @override
  void initState() {
    super.initState();
    final profile = widget.storage.loadProfile();
    _showTutorial = !profile.settings.tutorialSeen;
    _colorblind = profile.settings.colorblindMode;
  }

  /// Persist `tutorialSeen` BEFORE removing the overlay so it can never reappear
  /// on relaunch (failure mode: shows every launch).
  Future<void> _dismissTutorial() async {
    final profile = widget.storage.loadProfile();
    await widget.storage.saveProfile(profile.copyWith(
      settings: profile.settings.copyWith(tutorialSeen: true),
    ));
    if (mounted) setState(() => _showTutorial = false);
  }

  void _openStatsCalendar(BuildContext context, Difficulty difficulty) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StatsCalendarScreen(
          history: widget.storage.loadHistory(),
          initialDifficulty: difficulty,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: BlocConsumer<GameCubit, GameState>(
                    listener: (context, state) {
                      if (state is GameOverShowScore) {
                        final cubit = context.read<GameCubit>();
                        if (cubit.canOfferAd) {
                          _promptRewarded(context, cubit);
                        }
                      }
                      if (state is GamePlaying) {
                        // A new board state has dropped the previously-hinted
                        // tile; clear the stale reveal.
                        if (_hintTier != null) {
                          setState(() => _hintTier = null);
                        }
                      }
                    },
                    builder: (context, state) {
                      return switch (state) {
                        GameInitial() =>
                          const Center(child: CircularProgressIndicator()),
                        GameAdRewardGranted(:final board, :final difficulty) ||
                        GamePlaying(:final board, :final difficulty) =>
                          _buildPlaying(context, board, difficulty),
                        GameOverShowScore(
                          :final board,
                          :final date,
                          :final stats,
                          :final difficulty
                        ) =>
                          _buildResult(context, board, date, stats, difficulty),
                      };
                    },
                  ),
                ),
                BannerSlot(adService: adService),
              ],
            ),
            if (_showTutorial)
              Positioned.fill(
                child: TutorialOverlay(onDismiss: _dismissTutorial),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildResult(BuildContext context, BoardState board, String date,
      LifetimeStats stats, Difficulty difficulty) {
    final engagement = widget.engagement;
    final newly = engagement?.state.newlyUnlocked ?? const {};
    // Surface freshly-unlocked badges once, then clear them.
    if (newly.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        engagement?.acknowledgeNewlyUnlocked();
      });
    }
    final cubit = context.read<GameCubit>();

    // XP/level reflect the post-completion engagement state (the completion
    // hook fires before this screen builds).
    final xpGained = xpForScore(board.score);
    final level = engagement?.state.level ?? 0;
    final lifetimeXp = engagement?.state.lifetimeXp ?? 0;
    // Did THIS run's XP push the player up a level?
    final leveledUp = level > levelForXp(lifetimeXp - xpGained);

    return ScoreShareScreen(
      board: board,
      date: date,
      stats: stats,
      difficulty: difficulty,
      cosmetic: _cosmetic,
      friendCode: friendCode,
      newlyUnlocked: newly,
      nearMiss: NearMiss.message(board, bestScore: stats.bestScore),
      xpGained: xpGained,
      level: level,
      leveledUp: leveledUp,
      coinsEarned: cubit.coinsEarnedThisRun,
      coinsDoubled: cubit.coinsDoubled,
      onDoubleCoins: () => _watchDoubleCoins(context, cubit),
      canOfferAd: cubit.canOfferAd,
      onWatchAd: () => _watchRewarded(context, cubit),
      onMainMenu: () async {
        await cubit.submitIfPending();
        if (context.mounted) Navigator.of(context).pop();
      },
    );
  }

  /// Rewarded "double coins" on the result screen (Phase 2). On reward, credits
  /// the run's earned coins again, then refreshes so the button hides.
  void _watchDoubleCoins(BuildContext context, GameCubit cubit) {
    adService.showRewarded(
      adType: 'double_coins',
      onReward: () async {
        final bonus = await cubit.doubleRunCoins();
        if (bonus > 0) {
          widget.engagement?.refreshWallet();
          if (mounted) setState(() {}); // hide the button / reflect doubled
        }
      },
      onUnavailable: () {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No ad available right now.')),
          );
        }
      },
    );
  }

  Widget _buildPlaying(
      BuildContext context, BoardState board, Difficulty difficulty) {
    final cubit = context.read<GameCubit>();
    final engagement = widget.engagement;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // Challenge rule banner — shown at top when playing a challenge game.
          if (cubit.activeRule != null)
            Container(
              width: double.infinity,
              color: Colors.deepPurple.withValues(alpha: 0.85),
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
              child: Text(
                'Today: ${cubit.activeRule!.label}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ),
          if (engagement != null)
            BlocBuilder<EngagementCubit, EngagementState>(
              bloc: engagement,
              builder: (context, eng) {
                if (eng.dailyActiveStreak <= 0) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: StreakBanner(
                      streak: eng.dailyActiveStreak,
                      freezeTokens: eng.freezeTokens),
                );
              },
            ),
          Text(difficulty.label.toUpperCase(),
              style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          ObjectiveBanner(
              objective: cubit.objective, progress: board.objectiveProgress),
          const SizedBox(height: 8),
          MovesCounter(
              movesRemaining: board.movesRemaining, score: board.score),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              HintButton(
                enabled: cubit.canUseHint,
                onTap: () => _watchHint(context, cubit),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                key: const Key('undo-button'),
                onPressed: cubit.canUndo ? () => _undo(context, cubit) : null,
                icon: const Icon(Icons.undo, size: 18),
                label: const Text('Undo'),
              ),
              const SizedBox(width: 12),
              IconButton(
                key: const Key('open-stats-calendar'),
                tooltip: 'Stats calendar',
                icon: const Icon(Icons.calendar_month, color: Colors.white70),
                onPressed: () => _openStatsCalendar(context, difficulty),
              ),
              if (_hintTier != null) ...[
                const SizedBox(width: 12),
                HintReveal(tier: _hintTier!),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: BoardWidget(
                  board: board,
                  cosmetic: _cosmetic,
                  colorblindMode: _colorblind,
                  onChain: (path) => cubit.playChain(path),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          DropQueueRail(tiers: cubit.peekDropTiers(), cosmetic: _cosmetic),
        ],
      ),
    );
  }

  /// Undo the last merge (Phase 4). Uses a free undo if one remains; otherwise
  /// shows a rewarded ad and grants exactly one extra undo on reward. The undo
  /// rewinds board + landing-PRNG + move-log together (replay-consistent).
  void _undo(BuildContext context, GameCubit cubit) {
    if (cubit.canUndoFree) {
      cubit.undo();
      return;
    }
    // Out of free undos: gate the extra undo behind a rewarded ad.
    adService.showRewarded(
      adType: 'undo',
      onReward: () => cubit.undoAfterReward(),
      onUnavailable: () {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No ad available right now.')),
          );
        }
      },
    );
  }

  /// Show a rewarded ad; on reward, reveal the next drop tier (read-only).
  void _watchHint(BuildContext context, GameCubit cubit) {
    adService.showRewarded(
      adType: 'hint',
      onReward: () {
        final tier = cubit.revealNextDropAfterReward();
        if (tier != null && mounted) setState(() => _hintTier = tier);
      },
      onUnavailable: () {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No ad available right now.')),
          );
        }
      },
    );
  }

  void _promptRewarded(BuildContext context, GameCubit cubit) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => RewardedDialog(
        onWatch: () {
          Navigator.of(dialogContext).pop();
          _watchRewarded(context, cubit);
        },
        onDecline: () => Navigator.of(dialogContext).pop(),
      ),
    );
  }

  void _watchRewarded(BuildContext context, GameCubit cubit) {
    adService.showRewarded(
      adType: 'continue',
      onReward: () => cubit.grantAdReward(),
      onUnavailable: () {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No ad available right now.')),
          );
        }
      },
    );
  }
}
