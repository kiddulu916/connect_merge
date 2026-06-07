import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../application/game_cubit.dart';
import '../../application/game_state.dart';
import '../../domain/models/board_state.dart';
import '../../domain/models/difficulty.dart';
import '../../infrastructure/ad_service.dart';
import '../widgets/banner_slot.dart';
import '../widgets/board_widget.dart';
import '../widgets/moves_counter.dart';
import '../widgets/rewarded_dialog.dart';
import 'score_share_screen.dart';

class GameScreen extends StatelessWidget {
  final AdService adService;
  const GameScreen({super.key, required this.adService});

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
                },
                builder: (context, state) {
                  return switch (state) {
                    GameInitial() =>
                      const Center(child: CircularProgressIndicator()),
                    GameAdRewardGranted(:final board, :final difficulty) ||
                    GamePlaying(:final board, :final difficulty) =>
                      _buildPlaying(context, board, difficulty),
                    GameOverShowScore(:final board, :final date, :final stats) =>
                      ScoreShareScreen(
                        board: board,
                        date: date,
                        stats: stats,
                        canOfferAd: context.read<GameCubit>().canOfferAd,
                        onWatchAd: () =>
                            _watchRewarded(context, context.read<GameCubit>()),
                      ),
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

  Widget _buildPlaying(
      BuildContext context, BoardState board, Difficulty difficulty) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Text(difficulty.label.toUpperCase(),
              style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          MovesCounter(
              movesRemaining: board.movesRemaining, score: board.score),
          const SizedBox(height: 24),
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: BoardWidget(
                  board: board,
                  onMerge: (from, to) => context
                      .read<GameCubit>()
                      .merge(fromIndex: from, toIndex: to),
                ),
              ),
            ),
          ),
        ],
      ),
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
