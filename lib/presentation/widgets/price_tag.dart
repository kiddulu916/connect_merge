import 'package:flutter/material.dart';

/// A coin price + buy button for a purchasable cosmetic card (Phase 2).
///
/// Shows the [price] in coins and a Buy button that is enabled only when
/// [affordable]. When the player can't afford it the button is disabled (the
/// economy overspend guard is enforced in the cubit, but the UI reflects it).
class PriceTag extends StatelessWidget {
  final int price;
  final bool affordable;
  final VoidCallback onBuy;

  const PriceTag({
    super.key,
    required this.price,
    required this.affordable,
    required this.onBuy,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.monetization_on, color: Colors.amberAccent, size: 16),
        const SizedBox(width: 4),
        Text(
          '$price',
          key: const Key('price-amount'),
          style: TextStyle(
            color: affordable ? Colors.amberAccent : Colors.white38,
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          key: const Key('price-buy-button'),
          onPressed: affordable ? onBuy : null,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            minimumSize: const Size(0, 0),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Buy'),
        ),
      ],
    );
  }
}
