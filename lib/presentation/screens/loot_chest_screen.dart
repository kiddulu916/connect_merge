import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../application/loot_cubit.dart';
import '../../application/loot_state.dart';
import '../../infrastructure/ad_service.dart';
import '../widgets/coin_balance.dart';

/// The Daily Loot Chest screen: tap a sealed chest to reveal the day's
/// seed-derived reward, then optionally watch a rewarded ad to double it.
class LootChestScreen extends StatelessWidget {
  final LootCubit loot;
  final AdService adService;

  const LootChestScreen({
    super.key,
    required this.loot,
    required this.adService,
  });

  void _doubleWithAd(BuildContext context) {
    adService.showRewarded(
      onReward: () => loot.doubleReward(),
      onUnavailable: () {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No ad available right now.')),
          );
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF12141C),
      appBar: AppBar(
        backgroundColor: const Color(0xFF12141C),
        foregroundColor: Colors.white,
        title: const Text('Daily Chest'),
      ),
      body: SafeArea(
        child: BlocBuilder<LootCubit, LootState>(
          bloc: loot,
          builder: (context, state) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: CoinBalance(coins: state.coins),
                  ),
                  const Spacer(),
                  _body(context, state),
                  const Spacer(),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _body(BuildContext context, LootState state) {
    return switch (state) {
      LootReady() => Column(
          key: const Key('loot-ready'),
          children: [
            const Icon(Icons.card_giftcard,
                color: Colors.amberAccent, size: 96),
            const SizedBox(height: 24),
            const Text('Your daily chest is ready!',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('open-chest-button'),
              onPressed: () => loot.claim(),
              child: const Text('Open chest'),
            ),
          ],
        ),
      LootClaimed(:final reward) => Column(
          key: const Key('loot-claimed'),
          children: [
            const Icon(Icons.auto_awesome,
                color: Colors.amberAccent, size: 96),
            const SizedBox(height: 24),
            Text('+${reward.coins} coins',
                key: const Key('loot-reward-coins'),
                style: const TextStyle(
                    color: Colors.amberAccent,
                    fontSize: 32,
                    fontWeight: FontWeight.w900)),
            if (reward.shardCosmetic != null) ...[
              const SizedBox(height: 8),
              Text('Cosmetic shard: ${reward.shardCosmetic}',
                  style: const TextStyle(color: Colors.white70)),
            ],
            const SizedBox(height: 24),
            if (!reward.doubled)
              FilledButton.tonal(
                key: const Key('double-loot-button'),
                onPressed: () => _doubleWithAd(context),
                child: const Text('Watch ad to double it'),
              )
            else
              const Text('Doubled!',
                  style: TextStyle(
                      color: Colors.greenAccent,
                      fontWeight: FontWeight.w700)),
          ],
        ),
      LootSealed() => const Column(
          key: Key('loot-sealed'),
          children: [
            Icon(Icons.lock_clock, color: Colors.white38, size: 96),
            SizedBox(height: 24),
            Text('Come back tomorrow for your next chest.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 16)),
          ],
        ),
    };
  }
}
