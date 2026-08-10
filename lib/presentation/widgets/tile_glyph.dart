import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tile_palette.dart';

/// Renders a tile's tier numeral (always on) over an optional colorblind-safe
/// pattern (Phase 4). The numeral helps every player read the board; the pattern
/// is the opt-in accessibility layer, drawn as a subtle low-opacity overlay so
/// the value stays legible.
///
/// This composes ON TOP of the tile color from [GridCellWidget] — it never
/// replaces it — so it works across every cosmetic ramp.
class TileGlyph extends StatelessWidget {
  /// The tile's positive tier. Drives the numeral (2^tier) and pattern
  /// selection; live merges may exceed the tier-11 cosmetic milestone.
  final int tier;

  /// The tile face size in logical pixels (the glyph scales to it).
  final double size;

  /// When true, overlay the per-tier colorblind pattern behind the numeral.
  final bool colorblindMode;

  const TileGlyph({
    super.key,
    required this.tier,
    required this.size,
    this.colorblindMode = false,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (colorblindMode)
          // Subtle pattern overlay — distinguishes tiers without hue.
          Positioned.fill(
            child: CustomPaint(
              painter: _PatternPainter(TilePalette.patternForTier(tier)),
            ),
          ),
        Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: EdgeInsets.all(size * 0.12),
              child: Text(
                '${1 << tier}',
                style: TextStyle(
                  color: TilePalette.textColorForTier(tier),
                  fontWeight: FontWeight.w800,
                  fontSize: size * 0.34,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Paints a [TilePattern] as a subtle white overlay. Kept low-opacity so the
/// numeral stays the dominant, readable element.
class _PatternPainter extends CustomPainter {
  final TilePattern pattern;

  _PatternPainter(this.pattern);

  static const _alpha = 0.20;

  @override
  void paint(Canvas canvas, Size size) {
    if (pattern == TilePattern.none) return;
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: _alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, size.shortestSide * 0.06);
    final fill = Paint()..color = Colors.white.withValues(alpha: _alpha);
    final w = size.width;
    final h = size.height;
    final step = size.shortestSide / 4;

    switch (pattern) {
      case TilePattern.none:
        return;
      case TilePattern.dots:
        for (var y = step / 2; y < h; y += step) {
          for (var x = step / 2; x < w; x += step) {
            canvas.drawCircle(Offset(x, y), step * 0.14, fill);
          }
        }
      case TilePattern.stripesDiagonal:
        for (var d = -h; d < w; d += step) {
          canvas.drawLine(Offset(d, 0), Offset(d + h, h), paint);
        }
      case TilePattern.stripesHorizontal:
        for (var y = step / 2; y < h; y += step) {
          canvas.drawLine(Offset(0, y), Offset(w, y), paint);
        }
      case TilePattern.stripesVertical:
        for (var x = step / 2; x < w; x += step) {
          canvas.drawLine(Offset(x, 0), Offset(x, h), paint);
        }
      case TilePattern.grid:
        for (var y = step; y < h; y += step) {
          canvas.drawLine(Offset(0, y), Offset(w, y), paint);
        }
        for (var x = step; x < w; x += step) {
          canvas.drawLine(Offset(x, 0), Offset(x, h), paint);
        }
      case TilePattern.cross:
        canvas.drawLine(const Offset(0, 0), Offset(w, h), paint);
        canvas.drawLine(Offset(w, 0), Offset(0, h), paint);
      case TilePattern.checker:
        const cells = 4;
        final cw = w / cells;
        final ch = h / cells;
        for (var r = 0; r < cells; r++) {
          for (var c = 0; c < cells; c++) {
            if ((r + c).isEven) {
              canvas.drawRect(Rect.fromLTWH(c * cw, r * ch, cw, ch), fill);
            }
          }
        }
      case TilePattern.rings:
        final center = Offset(w / 2, h / 2);
        for (var r = step * 0.6; r < size.shortestSide; r += step * 0.8) {
          canvas.drawCircle(center, r, paint);
        }
    }
  }

  @override
  bool shouldRepaint(covariant _PatternPainter old) => old.pattern != pattern;
}
