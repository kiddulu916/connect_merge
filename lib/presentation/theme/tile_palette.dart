import 'package:flutter/material.dart';

/// Maps a tier to its tile color. Tier 0 (empty) uses a translucent slot color.
class TilePalette {
  const TilePalette._();

  static const _colors = <Color>[
    Color(0x14FFFFFF), // 0 empty slot
    Color(0xFF3B82F6), // 1
    Color(0xFF06B6D4), // 2
    Color(0xFF10B981), // 3
    Color(0xFF84CC16), // 4
    Color(0xFFEAB308), // 5
    Color(0xFFF59E0B), // 6
    Color(0xFFF97316), // 7
    Color(0xFFEF4444), // 8
    Color(0xFFEC4899), // 9
    Color(0xFFA855F7), // 10
    Color(0xFF7C3AED), // 11 (2048)
  ];

  static Color colorForTier(int tier) =>
      _colors[tier.clamp(0, _colors.length - 1)];

  static Color textColorForTier(int tier) => Colors.white;
}
