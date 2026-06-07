import 'package:flutter/material.dart';

import '../../domain/constants.dart';

/// Out-of-moves prompt offering a rewarded video for extra moves. Returns true
/// (via [onWatch]) when the user opts in, or dismisses otherwise.
class RewardedDialog extends StatelessWidget {
  final VoidCallback onWatch;
  final VoidCallback onDecline;

  const RewardedDialog({
    super.key,
    required this.onWatch,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Out of moves!'),
      content: const Text(
          'Watch a short video for +$kAdMoveReward moves and keep your run going.'),
      actions: [
        TextButton(onPressed: onDecline, child: const Text('No thanks')),
        FilledButton(
            onPressed: onWatch, child: const Text('Watch for +$kAdMoveReward')),
      ],
    );
  }
}
