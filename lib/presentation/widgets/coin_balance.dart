import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// A small wallet-balance pill reused across screens (Phase 1). The number
/// counts up/down when the balance changes (e.g. landing back on tier select
/// after a run credits this run's coins), so the gain is visible rather than
/// snapping. The first render is static — only a subsequent change animates.
class CoinBalance extends StatefulWidget {
  final int coins;

  /// When set, the FIRST render animates from this value up to [coins] instead
  /// of showing [coins] statically. Used to replay the count-up on-screen (e.g.
  /// landing on tier-select after a run) even though the balance already changed
  /// while the pill was in the background — pair it with a changing [key] so the
  /// State re-initialises and the animation actually runs.
  final int? animateFrom;

  const CoinBalance({super.key, required this.coins, this.animateFrom});

  @override
  State<CoinBalance> createState() => _CoinBalanceState();
}

class _CoinBalanceState extends State<CoinBalance> {
  late int _from;

  @override
  void initState() {
    super.initState();
    // First render is static unless an explicit start value is given.
    _from = widget.animateFrom ?? widget.coins;
  }

  @override
  void didUpdateWidget(covariant CoinBalance oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coins != widget.coins) _from = oldWidget.coins;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('coin-balance'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.monetization_on, color: Colors.amberAccent, size: 18),
          const SizedBox(width: 6),
          TweenAnimationBuilder<int>(
            // A key tied to the target restarts the tween from [_from] each time
            // the balance changes, so the count runs old -> new.
            key: ValueKey<int>(widget.coins),
            tween: IntTween(begin: _from, end: widget.coins),
            duration: const Duration(milliseconds: 900),
            curve: Curves.easeOut,
            builder: (context, value, _) => Text('$value',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }
}
