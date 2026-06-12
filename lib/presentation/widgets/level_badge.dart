import 'package:flutter/material.dart';

/// A compact player-level chip (Phase 2), shown on the profile and leaderboard
/// rows as flair. Purely cosmetic — the level is client-side and never affects
/// score or fairness.
class LevelBadge extends StatelessWidget {
  final int level;

  /// Smaller, denser variant for tight rows (e.g. leaderboard list tiles).
  final bool compact;

  const LevelBadge({super.key, required this.level, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final double fontSize = compact ? 11 : 13;
    final EdgeInsets pad = compact
        ? const EdgeInsets.symmetric(horizontal: 6, vertical: 2)
        : const EdgeInsets.symmetric(horizontal: 10, vertical: 4);
    return Container(
      key: const Key('level-badge'),
      padding: pad,
      decoration: BoxDecoration(
        color: const Color(0xFF2A2F40),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded,
              color: Colors.amberAccent, size: fontSize + 3),
          const SizedBox(width: 3),
          Text(
            'Lv $level',
            style: TextStyle(
              color: Colors.white,
              fontSize: fontSize,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
