import 'package:flutter/material.dart';

/// Design tokens for Connect Merge.
///
/// Single source of truth for color, spacing and radius. Screens should
/// reference these semantic names instead of hardcoding hex / opacity values,
/// so the palette can be tuned in one place (and a light theme added later).
///
/// Matches the existing static-class convention (see [TilePalette]); all values
/// are `const` so callers stay const-constructible.
class AppColors {
  const AppColors._();

  // --- Surfaces ---
  /// App background (deepest layer).
  static const Color background = Color(0xFF12141C);

  /// Default card / control surface sitting on the background.
  static const Color surface = Color(0xFF1B1E2A);

  /// Slightly raised surface for pressed / hovered / highlighted states.
  static const Color surfaceBright = Color(0xFF242838);

  // --- Brand / accent ---
  /// Primary accent (amber). Used for the live daily-chest CTA and emphasis.
  static const Color accent = Color(0xFFFFA000); // Colors.amber.shade700

  /// Success / completion (e.g. "Done today").
  static const Color success = Color(0xFF69F0AE); // Colors.greenAccent

  // --- Text & icon emphasis (on dark surfaces) ---
  /// High-emphasis text (titles, primary labels).
  static const Color textPrimary = Color(0xFFFFFFFF);

  /// Secondary text / app-bar icons.
  static const Color textSecondary = Color(0xB3FFFFFF); // white70

  /// Muted text (supporting labels, inactive icons).
  static const Color textMuted = Color(0x8AFFFFFF); // white54

  /// Faint text (captions, metadata).
  static const Color textFaint = Color(0x61FFFFFF); // white38

  /// Hairline borders / dividers / outlined-button strokes.
  static const Color border = Color(0x3DFFFFFF); // white24
}

/// 4 / 8 px spacing scale. Use these for padding, gaps and section rhythm
/// instead of arbitrary pixel values.
class AppSpacing {
  const AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
}

/// Corner-radius scale for cards, controls and pills.
class AppRadii {
  const AppRadii._();

  static const double sm = 12;
  static const double md = 16;
  static const double pill = 999;
}
