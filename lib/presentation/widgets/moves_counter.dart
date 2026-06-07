import 'package:flutter/material.dart';

class MovesCounter extends StatelessWidget {
  final int movesRemaining;
  final int score;

  const MovesCounter({
    super.key,
    required this.movesRemaining,
    required this.score,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _stat(context, 'MOVES', '$movesRemaining'),
        _stat(context, 'SCORE', '$score'),
      ],
    );
  }

  Widget _stat(BuildContext context, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 12, letterSpacing: 1.5, color: Colors.white54)),
        Text(value,
            style: const TextStyle(
                fontSize: 28, fontWeight: FontWeight.w800, color: Colors.white)),
      ],
    );
  }
}
