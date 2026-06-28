import 'package:flutter/material.dart';

import '../../domain/models/achievement.dart';
import '../theme/tokens.dart';

/// A grid of all achievements, showing locked vs unlocked state. Pure
/// presentation: the caller passes the currently-unlocked set (from
/// [EngagementCubit] / storage).
class AchievementsScreen extends StatelessWidget {
  final Set<Achievement> unlocked;

  const AchievementsScreen({super.key, required this.unlocked});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        foregroundColor: Colors.white,
        title: const Text('Achievements'),
      ),
      body: GridView.count(
        key: const Key('achievements-grid'),
        padding: const EdgeInsets.all(16),
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.4,
        children: [
          for (final a in Achievement.values)
            _Badge(achievement: a, isUnlocked: unlocked.contains(a)),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final Achievement achievement;
  final bool isUnlocked;

  const _Badge({required this.achievement, required this.isUnlocked});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('badge-${achievement.name}'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isUnlocked ? Colors.amberAccent : Colors.white12,
          width: isUnlocked ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isUnlocked ? Icons.emoji_events : Icons.lock_outline,
            color: isUnlocked ? Colors.amberAccent : Colors.white38,
            size: 28,
          ),
          const Spacer(),
          Text(achievement.label,
              style: TextStyle(
                  color: isUnlocked ? Colors.white : Colors.white54,
                  fontSize: 16,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(achievement.description,
              style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ),
    );
  }
}
