import 'package:flutter/material.dart';

import '../../domain/models/tile.dart';
import '../theme/tile_palette.dart';

/// Renders a single tile face (or an empty slot if [tile] is null).
class GridCellWidget extends StatelessWidget {
  final Tile? tile;
  final double size;

  const GridCellWidget({super.key, required this.tile, required this.size});

  @override
  Widget build(BuildContext context) {
    final t = tile;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: TilePalette.colorForTier(t?.tier ?? 0),
        borderRadius: BorderRadius.circular(size * 0.16),
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
