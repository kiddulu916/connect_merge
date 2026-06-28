import 'package:flutter/material.dart';

import '../../application/rivalry_cubit.dart';
import '../theme/tokens.dart';

/// Persistent you-vs-rival chip (Phase 3), shown on the game / result screens.
///
/// Renders the [rivalName] and the signed delta from a [RivalDelta]. Ahead is
/// green, behind is red, tied is neutral. The name is ellipsized so a long
/// display name never overflows the chip.
class RivalIndicator extends StatelessWidget {
  final String rivalName;
  final RivalDelta delta;

  const RivalIndicator({
    super.key,
    required this.rivalName,
    required this.delta,
  });

  @override
  Widget build(BuildContext context) {
    final Color accent = delta.amAhead
        ? Colors.greenAccent
        : delta.amBehind
            ? Colors.redAccent
            : Colors.white54;
    final String deltaText = delta.tied
        ? 'Tied'
        : delta.amAhead
            ? '+${delta.delta}'
            : '${delta.delta}'; // already negative

    return Container(
      key: const Key('rival-indicator'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.flag_rounded, color: accent, size: 16),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              'vs $rivalName',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            deltaText,
            key: const Key('rival-delta'),
            style: TextStyle(
                color: accent, fontWeight: FontWeight.w800, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
