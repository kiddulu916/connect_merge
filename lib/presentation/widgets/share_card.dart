import 'package:flutter/material.dart';

import '../../domain/models/board_state.dart';
import '../../domain/models/cosmetic.dart';
import '../../domain/models/difficulty.dart';
import '../../domain/models/tile.dart';
import '../theme/tile_palette.dart';
import '../theme/tokens.dart';
import 'level_badge.dart';

/// The rendered, screenshot-worthy result card (Phase 3 richer share card).
///
/// A polished, self-contained snapshot: the final board art, headline score,
/// highest tile, streak flex, optional rank badge, and player level. It is wrapped
/// in a [RepaintBoundary] by the share screen and captured to PNG via
/// [ShareCardRenderer], so it must lay out with NO interaction and NO overflow
/// regardless of inputs.
///
/// Robustness guarantees (verified by the extreme cases in tests / manual QA):
///  - an all-empty board renders (no tiles) without clipping;
///  - a jackpot board (every cell a high tile) fits the fixed mini-grid;
///  - a long display name ellipsizes instead of overflowing.
class ShareCard extends StatelessWidget {
  final BoardState board;
  final Difficulty difficulty;
  final int score;
  final int highestTier;
  final int streak;
  final int level;

  /// The player's display name (ellipsized). Null hides the name line.
  final String? displayName;

  /// Leaderboard rank to flex as a badge. Null/<=0 hides the rank badge.
  final int? rank;

  /// Tile theme for the mini-board art.
  final Cosmetic cosmetic;

  const ShareCard({
    super.key,
    required this.board,
    required this.difficulty,
    required this.score,
    required this.highestTier,
    required this.streak,
    required this.level,
    this.displayName,
    this.rank,
    this.cosmetic = Cosmetic.classic,
  });

  @override
  Widget build(BuildContext context) {
    final hasRank = rank != null && rank! > 0;
    return Container(
      key: const Key('share-card'),
      width: 360,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.surface, AppColors.background],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text('MERGE COUNT',
                  style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      letterSpacing: 3,
                      fontWeight: FontWeight.w800)),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2F40),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(difficulty.label.toUpperCase(),
                    key: const Key('share-card-difficulty'),
                    style: const TextStyle(
                        color: Colors.cyanAccent,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1)),
              ),
            ],
          ),
          if (displayName != null) ...[
            const SizedBox(height: 8),
            Text(
              displayName!,
              key: const Key('share-card-name'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700),
            ),
          ],
          const SizedBox(height: 16),
          Center(child: _MiniBoard(board: board, cosmetic: cosmetic)),
          const SizedBox(height: 18),
          const Text('SCORE',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.white54, letterSpacing: 2, fontSize: 12)),
          Text('$score',
              key: const Key('share-card-score'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 44,
                  fontWeight: FontWeight.w900)),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _stat('BEST TILE', '${1 << highestTier}'),
              _stat('STREAK', '$streak'),
              if (hasRank) _stat('RANK', '#${rank!}'),
            ],
          ),
          const SizedBox(height: 16),
          Center(child: LevelBadge(level: level)),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: const TextStyle(
                  color: Colors.white38, fontSize: 10, letterSpacing: 1.5)),
          const SizedBox(height: 2),
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800)),
        ],
      );
}

/// A static, non-interactive miniature of the final board for the share card.
/// Fixed size so the card layout is deterministic for any board (empty .. full).
class _MiniBoard extends StatelessWidget {
  final BoardState board;
  final Cosmetic cosmetic;

  const _MiniBoard({required this.board, required this.cosmetic});

  @override
  Widget build(BuildContext context) {
    const double size = 220;
    const double gap = 4;
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(gap),
      decoration: BoxDecoration(
        color: const Color(0xFF1E2230),
        borderRadius: BorderRadius.circular(12),
      ),
      child: GridView.count(
        crossAxisCount: board.gridSize,
        mainAxisSpacing: gap,
        crossAxisSpacing: gap,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (var i = 0; i < board.cells.length; i++)
            _MiniCell(
                tile: board.cells[i],
                cosmetic: cosmetic),
        ],
      ),
    );
  }
}

class _MiniCell extends StatelessWidget {
  final Tile? tile;
  final Cosmetic cosmetic;

  const _MiniCell({
    required this.tile,
    required this.cosmetic,
  });

  @override
  Widget build(BuildContext context) {
    final t = tile;
    if (t == null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF2A2F40),
          borderRadius: BorderRadius.circular(6),
        ),
      );
    }
    final int tier = t.tier;
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: TilePalette.colorFor(cosmetic, tier),
        borderRadius: BorderRadius.circular(6),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Text('${1 << tier}',
              style: TextStyle(
                  color: TilePalette.textColorForTier(tier),
                  fontWeight: FontWeight.w800,
                  fontSize: 14)),
        ),
      ),
    );
  }
}
