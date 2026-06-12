import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../application/engagement_cubit.dart';
import '../../application/game_cubit.dart';
import '../../application/game_state.dart';
import '../../domain/engine/near_miss.dart';
import '../../domain/models/board_state.dart';
import '../../domain/models/cosmetic.dart';
import '../../domain/models/player_level.dart';
import '../../infrastructure/storage_service.dart';
import '../../domain/models/difficulty.dart';
import '../../infrastructure/ad_service.dart';
import '../../infrastructure/notification_service.dart';
import '../widgets/banner_slot.dart';
import '../widgets/board_widget.dart';
import '../widgets/hint_button.dart';
import '../widgets/moves_counter.dart';
import '../widgets/rewarded_dialog.dart';
import '../widgets/streak_banner.dart';
import 'score_share_screen.dart';

class GameScreen extends StatefulWidget {
  final AdService adService;

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

  AdService get adService => widget.adService;
  String? get friendCode => widget.friendCode;

  Cosmetic get _cosmetic =>
      widget.engagement?.state.selectedCosmetic ?? Cosmetic.classic;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF12141C),
      body: SafeArea(
        child: Column(
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
                    // A new board state has dropped the previously-hinted tile;
                    // clear the stale reveal.
                    if (_hintTier != null) setState(() => _hintTier = null);
                  }
                },
                builder: (context, state) {
                  return switch (state) {
                    GameInitial() =>
                      const Center(child: CircularProgressIndicator()),
                    GameAdRewardGranted(:final board, :final difficulty) ||
                    GamePlaying(:final board, :final difficulty) =>
                      _buildPlaying(context, board, difficulty),
                    GameOverShowScore(:final board, :final date, :final stats) =>
                      _buildResult(context, board, date, stats),
                  };
                },
              ),
            ),
            BannerSlot(adService: adService),
          ],
        ),
      ),
    );
  }

  Widget _buildResult(BuildContext context, BoardState board, String date,
      LifetimeStats stats) {
    final engagement = widget.engagement;
    final newly = engagement?.state.newlyUnlocked ?? const {};
    // Surface freshly-unlocked badges once, then clear them.
    if (newly.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        engagement?.acknowledgeNewlyUnlocked();
      });
    }
    final cubit = context.read<GameCubit>();

    // Phase 2 meta-progression flair. XP/level reflect the post-completion
    // engagement state (the completion hook fires before this screen builds).
    final xpGained = xpForScore(board.score);
    final level = engagement?.state.level ?? 0;
    final lifetimeXp = engagement?.state.lifetimeXp ?? 0;
    // Did THIS run's XP push the player up a level?
    final leveledUp = level > levelForXp(lifetimeXp - xpGained);

    return ScoreShareScreen(
      board: board,
      date: date,
      stats: stats,
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
      onMainMenu: () => Navigator.of(context).pop(),
    );
  }

  /// Rewarded "double coins" on the result screen (Phase 2). On reward, credits
  /// the run's earned coins again, then refreshes so the button hides.
  void _watchDoubleCoins(BuildContext context, GameCubit cubit) {
    adService.showRewarded(
      onReward: () {
        final bonus = cubit.doubleRunCoins();
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
                  onMerge: (from, to) =>
                      cubit.merge(fromIndex: from, toIndex: to),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Show a rewarded ad; on reward, reveal the next drop tier (read-only).
  void _watchHint(BuildContext context, GameCubit cubit) {
    adService.showRewarded(
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
