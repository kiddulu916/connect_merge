import 'package:flutter/material.dart';

import '../../domain/models/cosmetic.dart';
import '../../domain/models/tile.dart';
import '../theme/tile_palette.dart';

/// Renders a single tile face (or an empty slot if [tile] is null).
class GridCellWidget extends StatelessWidget {
  final Tile? tile;
  final double size;

  /// Selected tile theme. Defaults to classic (the original ramp).
  final Cosmetic cosmetic;

  const GridCellWidget({
    super.key,
    required this.tile,
    required this.size,
    this.cosmetic = Cosmetic.classic,
  });

  @override
  Widget build(BuildContext context) {
    final t = tile;
    final golden = t?.golden ?? false;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: TilePalette.colorFor(cosmetic, t?.tier ?? 0),
        borderRadius: BorderRadius.circular(size * 0.16),
        // Golden tiles (Phase 1) get a warm sparkle border so the in-loop
        // variable reward reads instantly. Purely visual.
        border: golden
            ? Border.all(color: Colors.amberAccent, width: size * 0.06)
            : null,
        boxShadow: golden
            ? [
                BoxShadow(
                  color: Colors.amberAccent.withValues(alpha: 0.6),
                  blurRadius: size * 0.2,
                ),
              ]
            : null,
      ),
      alignment: Alignment.center,
      child: t == null
          ? null
          : FittedBox(
              fit: BoxFit.scaleDown,
              child: Padding(
                padding: EdgeInsets.all(size * 0.12),
                child: Text(
                  '${t.value}',
                  style: TextStyle(
                    color: TilePalette.textColorForTier(t.tier),
                    fontWeight: FontWeight.w800,
                    fontSize: size * 0.34,
                  ),
                ),
              ),
            ),
    );
  }
}
