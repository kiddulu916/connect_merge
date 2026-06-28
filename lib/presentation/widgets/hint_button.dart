import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Rewarded "reveal the next drop" hint button. Pure presentation: the parent
/// decides whether a hint is available ([enabled]) and what happens on tap
/// ([onTap] — show the rewarded ad, then reveal via
/// `GameCubit.revealNextDropAfterReward`). The hint is READ-ONLY (it reveals
/// seed-fixed info and never alters the board), so it cannot affect fairness.
class HintButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;

  const HintButton({super.key, required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      key: const Key('hint-button'),
      onPressed: enabled ? onTap : null,
      icon: const Icon(Icons.lightbulb_outline, size: 18),
      label: const Text('Hint: next drop'),
    );
  }
}

/// A small, non-intrusive reveal of the next drop tier (its 2^tier value).
/// Shown after a rewarded hint succeeds. Read-only display.
class HintReveal extends StatelessWidget {
  final int tier;
  const HintReveal({super.key, required this.tier});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('hint-reveal'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('Next drop: ${1 << tier}',
          style: const TextStyle(
              color: Colors.amberAccent, fontWeight: FontWeight.w700)),
    );
  }
}
