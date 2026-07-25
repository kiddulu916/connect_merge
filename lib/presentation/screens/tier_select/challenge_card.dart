import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

const _challengeAccent = Color(0xFF9C27B0); // deep purple / violet

/// Formats [d] as `HH:MM:SS`, clock-style. Shared by the challenge-unlock and
/// daily-reset countdowns.
String formatCountdown(Duration d) {
  final h = d.inHours.toString().padLeft(2, '0');
  final m = (d.inMinutes % 60).toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$h:$m:$s';
}

/// The Daily Challenge tile on the tier-select screen, in one of three states:
///   * Locked ([unlocked] false): countdown + rule teaser + lock icon
///   * Unlocked, not played ([unlocked] true, [completed] false): rule label + Play button
///   * Completed ([completed] true): Done check + rule label
///
/// Extracted from tier_select_screen.dart. Every input the three states
/// depend on — including the unlock countdown, previously read from
/// `DateTime.now()` inside build() — is a constructor parameter, so this
/// widget is fully deterministic to test.
class ChallengeCard extends StatelessWidget {
  final bool unlocked;
  final bool completed;
  final String ruleName;

  /// Time remaining until noon UTC. Only shown when [unlocked] is false.
  final Duration timeUntilUnlock;
  final VoidCallback onPlay;

  const ChallengeCard({
    super.key,
    required this.unlocked,
    required this.completed,
    required this.ruleName,
    required this.timeUntilUnlock,
    required this.onPlay,
  });

  Widget _frame({required Widget child}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: AnimatedScale(
        scale: 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Material(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.md),
          child: InkWell(
            key: const Key('tier-challenge'),
            borderRadius: BorderRadius.circular(AppRadii.md),
            onTap: (!unlocked || completed) ? null : onPlay,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadii.md),
                border: Border.all(
                  color: completed
                      ? AppColors.success.withValues(alpha: 0.45)
                      : _challengeAccent.withValues(alpha: 0.50),
                  width: 1.5,
                ),
              ),
              padding: const EdgeInsets.all(20),
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!unlocked) {
      return _frame(
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: _challengeAccent.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(AppRadii.sm),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.lock_clock,
                  size: 26, color: _challengeAccent),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Daily Challenge',
                      style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: AppSpacing.xs),
                  Text('Today: $ruleName',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.textMuted, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(
                    'Opens in ${formatCountdown(timeUntilUnlock)}',
                    style: const TextStyle(
                        color: _challengeAccent,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    if (completed) {
      return _frame(
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.success.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(AppRadii.sm),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.check_circle,
                  size: 28, color: AppColors.success),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Daily Challenge',
                      style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 20,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Done today ✓  ·  $ruleName',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.success,
                        fontSize: 13,
                        fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return _frame(
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: _challengeAccent,
              borderRadius: BorderRadius.circular(AppRadii.sm),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.bolt, size: 28, color: Colors.white),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Daily Challenge',
                    style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: AppSpacing.xs),
                Text('Today: $ruleName',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textFaint, fontSize: 13)),
              ],
            ),
          ),
          FilledButton(
            key: const Key('play-challenge'),
            onPressed: onPlay,
            style: FilledButton.styleFrom(
              backgroundColor: _challengeAccent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Play',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}
