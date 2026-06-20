import 'package:flutter/material.dart';

import '../../domain/models/daily_objective.dart';

/// The day's bonus goal and progress. Read-only flair; reward is credited by the
/// cubit when met.
class ObjectiveBanner extends StatelessWidget {
  final DailyObjective objective;
  final int progress;

  const ObjectiveBanner({
    super.key,
    required this.objective,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final met = objective.isMet(progress);
    final shown = progress > objective.target ? objective.target : progress;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E2230),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(met ? Icons.check_circle : Icons.flag,
              size: 18, color: met ? Colors.greenAccent : Colors.white70),
          const SizedBox(width: 8),
          Text(objective.label,
              style: const TextStyle(color: Colors.white, fontSize: 13)),
          const SizedBox(width: 10),
          Text('$shown/${objective.target}',
              style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 13,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
