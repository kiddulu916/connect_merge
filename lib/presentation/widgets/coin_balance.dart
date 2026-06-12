import 'package:flutter/material.dart';

/// A small wallet-balance pill reused across screens (Phase 1).
class CoinBalance extends StatelessWidget {
  final int coins;

  const CoinBalance({super.key, required this.coins});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('coin-balance'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1E2A),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.monetization_on, color: Colors.amberAccent, size: 18),
          const SizedBox(width: 6),
          Text('$coins',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}
