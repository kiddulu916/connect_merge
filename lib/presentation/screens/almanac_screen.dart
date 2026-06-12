import 'package:flutter/material.dart';

import '../../domain/constants.dart';
import '../../domain/models/almanac.dart';
import '../../domain/models/cosmetic.dart';
import '../../domain/models/player_level.dart';
import '../theme/tile_palette.dart';
import '../widgets/level_badge.dart';

/// The Merge Almanac — a fillable "book" of every tile tier, how many times the
/// player has reached it, and a mastery badge that fills with progress. Pure
/// presentation: the caller passes the [almanac] + [lifetimeXp] (from
/// [EngagementCubit]). None of this affects score; it is collection flair.
class AlmanacScreen extends StatelessWidget {
  final Almanac almanac;
  final int lifetimeXp;

  /// The selected cosmetic, used to tint each tier's swatch so the book matches
  /// the player's current theme.
  final Cosmetic cosmetic;

  const AlmanacScreen({
    super.key,
    required this.almanac,
    required this.lifetimeXp,
    this.cosmetic = Cosmetic.classic,
  });

  @override
  Widget build(BuildContext context) {
    final level = levelForXp(lifetimeXp);
    final entries = almanac.entries.reversed.toList(); // highest tier first
    return Scaffold(
      backgroundColor: const Color(0xFF12141C),
      appBar: AppBar(
        backgroundColor: const Color(0xFF12141C),
        foregroundColor: Colors.white,
        title: const Text('Merge Almanac'),
      ),
      body: ListView(
        key: const Key('almanac-list'),
        padding: const EdgeInsets.all(16),
        children: [
          _header(level),
          const SizedBox(height: 16),
          for (final e in entries) _tierCard(e),
        ],
      ),
    );
  }

  Widget _header(int level) {
    return Container(
      key: const Key('almanac-header'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1E2A),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          LevelBadge(level: level),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${almanac.discoveredCount} discovered · ${almanac.masteredCount} mastered',
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                _xpBar(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _xpBar() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: LinearProgressIndicator(
        key: const Key('almanac-xp-bar'),
        value: levelProgress(lifetimeXp),
        minHeight: 6,
        backgroundColor: Colors.white12,
        valueColor: const AlwaysStoppedAnimation(Colors.amberAccent),
      ),
    );
  }

  Widget _tierCard(AlmanacEntry e) {
    final mastered = e.mastered;
    final discovered = e.count > 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        key: Key('almanac-tier-${e.tier}'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF1B1E2A),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: mastered ? Colors.amberAccent : Colors.white12,
            width: mastered ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: discovered
                    ? TilePalette.colorFor(cosmetic, e.tier)
                    : Colors.white10,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                discovered ? '${e.value}' : '?',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        discovered ? 'Tile ${e.value}' : 'Undiscovered',
                        style: TextStyle(
                            color: discovered ? Colors.white : Colors.white54,
                            fontSize: 15,
                            fontWeight: FontWeight.w800),
                      ),
                      const Spacer(),
                      if (mastered)
                        const Icon(Icons.workspace_premium,
                            color: Colors.amberAccent, size: 18),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Reached ${e.count}× · ${mastered ? 'Mastered' : '${e.count}/$kAlmanacMasteryThreshold to master'}',
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: e.progress,
                      minHeight: 5,
                      backgroundColor: Colors.white12,
                      valueColor: AlwaysStoppedAnimation(
                          mastered ? Colors.amberAccent : Colors.white54),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
