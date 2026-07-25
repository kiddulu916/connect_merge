import 'package:flutter/material.dart';

import '../../../domain/models/difficulty.dart';
import '../../theme/tokens.dart';

/// A single difficulty tier as a tappable "hero" card.
///
/// Stateful only to drive a subtle press-scale ([scale-feedback]); the InkWell
/// still supplies the ripple and is the keyed tap target the tests drive. A
/// completed card switches to a success-tinted outline + check badge and is
/// non-interactive.
class TierCard extends StatefulWidget {
  final Difficulty difficulty;
  final bool completed;
  final Color accent;

  /// 0-based difficulty rank; drives the 1–4 pip indicator.
  final int rank;

  /// Tap handler. Null when the tier is already completed (card is inert).
  final VoidCallback? onTap;
  final VoidCallback onPractice;
  final GlobalKey? practiceTargetKey;

  /// Opens the per-tier leaderboard; null hides the icon (offline).
  final VoidCallback? onLeaderboard;

  const TierCard({
    super.key,
    required this.difficulty,
    required this.completed,
    required this.accent,
    required this.rank,
    required this.onTap,
    required this.onPractice,
    this.practiceTargetKey,
    required this.onLeaderboard,
  });

  @override
  State<TierCard> createState() => _TierCardState();
}

class _TierCardState extends State<TierCard> {
  bool _pressed = false;

  /// Compact trailing-action button (20px glyph, 36px hit area) so the practice
  /// + per-tier leaderboard icons leave the label room to render in full.
  Widget _cardIconButton({
    required Key iconKey,
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      key: iconKey,
      tooltip: tooltip,
      icon: Icon(icon, color: AppColors.textMuted),
      iconSize: 20,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        minimumSize: const Size(36, 36),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.difficulty;
    final completed = widget.completed;
    final accent = widget.accent;

    return AnimatedScale(
      scale: _pressed ? 0.97 : 1.0,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: InkWell(
          key: Key('tier-${d.name}'),
          borderRadius: BorderRadius.circular(AppRadii.md),
          onTap: widget.onTap,
          onHighlightChanged: (v) => setState(() => _pressed = v),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(
                color: completed
                    ? AppColors.success.withValues(alpha: 0.45)
                    : accent.withValues(alpha: 0.35),
                width: 1.5,
              ),
            ),
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: completed ? 0.3 : 1.0),
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                  ),
                  alignment: Alignment.center,
                  child: Text('${d.startingFill}',
                      style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // The label gets the full column width on its own line and
                      // a scale-down FittedBox so longer tiers (e.g. "Legendary")
                      // render in full — never ellipsized — even with the online
                      // per-tier leaderboard icon present. It keeps full size on
                      // real-device widths and only shrinks on very narrow ones.
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(d.label,
                              maxLines: 1,
                              softWrap: false,
                              style: TextStyle(
                                  color: completed
                                      ? AppColors.textMuted
                                      : AppColors.textPrimary,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800)),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      // Difficulty pips + status share the second line; the
                      // status can ellipsize (never the fixed trailing row), so
                      // the card never overflows on narrow phones.
                      Row(
                        children: [
                          DifficultyPips(
                            filled: widget.rank + 1,
                            total: Difficulty.values.length,
                            color: accent,
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Text(
                              completed
                                  ? 'Done today ✓'
                                  : '${d.startingFill} starting tiles',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: completed
                                      ? AppColors.success
                                      : AppColors.textFaint,
                                  fontSize: 13,
                                  fontWeight: completed
                                      ? FontWeight.w700
                                      : FontWeight.w400),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                KeyedSubtree(
                  key: widget.practiceTargetKey,
                  child: _cardIconButton(
                    iconKey: Key('practice-${d.name}'),
                    tooltip: 'Practice',
                    icon: Icons.fitness_center,
                    onPressed: widget.onPractice,
                  ),
                ),
                if (widget.onLeaderboard != null)
                  _cardIconButton(
                    iconKey: Key('leaderboard-${d.name}'),
                    tooltip: 'Leaderboard',
                    icon: Icons.leaderboard,
                    onPressed: widget.onLeaderboard!,
                  ),
                Icon(
                  completed ? Icons.check_circle : Icons.chevron_right,
                  color: completed ? AppColors.success : AppColors.textMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact 1-of-N difficulty meter rendered as filled/empty dots.
class DifficultyPips extends StatelessWidget {
  final int filled;
  final int total;
  final Color color;

  const DifficultyPips({
    super.key,
    required this.filled,
    required this.total,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < total; i++)
          Padding(
            padding: const EdgeInsets.only(right: 3),
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < filled ? color : AppColors.border,
              ),
            ),
          ),
      ],
    );
  }
}
