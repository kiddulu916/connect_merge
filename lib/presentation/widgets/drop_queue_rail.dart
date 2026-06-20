import 'package:flutter/material.dart';

import '../../domain/models/cosmetic.dart';
import '../theme/tile_palette.dart';

/// Shows the next few drop tiers openly (the planning queue). Read-only flair.
class DropQueueRail extends StatelessWidget {
  final List<int> tiers;
  final Cosmetic cosmetic;

  const DropQueueRail({
    super.key,
    required this.tiers,
    this.cosmetic = Cosmetic.classic,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('NEXT  ',
            style: TextStyle(
                color: Colors.white54,
                fontSize: 12,
                letterSpacing: 2,
                fontWeight: FontWeight.w700)),
        for (final tier in tiers)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: TilePalette.colorFor(cosmetic, tier),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('${1 << tier}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold)),
            ),
          ),
      ],
    );
  }
}
