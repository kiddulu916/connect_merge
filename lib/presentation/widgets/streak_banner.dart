import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Compact headline-streak banner with an optional rewarded streak-freeze CTA.
/// Pure presentation — the parent supplies the current streak/token count and
/// the freeze callback (which wires the rewarded ad + [EngagementCubit]).
class StreakBanner extends StatelessWidget {
  final int streak;
  final int freezeTokens;

  /// Invoked when the player taps the freeze CTA (parent shows a rewarded ad,
  /// then grants a token). When null, the CTA is hidden.
  final VoidCallback? onFreeze;

  const StreakBanner({
    super.key,
    required this.streak,
    required this.freezeTokens,
    this.onFreeze,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('streak-banner'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Icons.local_fire_department,
              color: Colors.deepOrangeAccent, size: 22),
          const SizedBox(width: 8),
          Text(
            '$streak-day streak',
            key: const Key('streak-count'),
            style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w800),
          ),
          const Spacer(),
          if (freezeTokens > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                children: [
                  const Icon(Icons.ac_unit,
                      color: Colors.lightBlueAccent, size: 18),
                  const SizedBox(width: 2),
                  Text('$freezeTokens',
                      key: const Key('freeze-count'),
                      style: const TextStyle(
                          color: Colors.lightBlueAccent,
                          fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          if (onFreeze != null)
            TextButton.icon(
              key: const Key('freeze-cta'),
              onPressed: onFreeze,
              icon: const Icon(Icons.ac_unit, size: 16),
              label: const Text('Freeze'),
            ),
        ],
      ),
    );
  }
}
