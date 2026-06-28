import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../application/engagement_cubit.dart';
import '../../domain/models/cosmetic.dart';
import '../../infrastructure/ad_service.dart';
import '../theme/tile_palette.dart';
import '../theme/tokens.dart';
import '../widgets/coin_balance.dart';
import '../widgets/price_tag.dart';

/// Pick a tile theme. Unlocked cosmetics are selectable; locked ones show their
/// unlock requirement. A rewarded-ad cosmetic can be unlocked in-place; a
/// purchase cosmetic can be bought with coins (Phase 2).
class CosmeticsScreen extends StatefulWidget {
  final EngagementCubit engagement;
  final AdService adService;

  const CosmeticsScreen({
    super.key,
    required this.engagement,
    required this.adService,
  });

  @override
  State<CosmeticsScreen> createState() => _CosmeticsScreenState();
}

class _CosmeticsScreenState extends State<CosmeticsScreen> {
  @override
  void initState() {
    super.initState();
    // Coins can be credited outside this cubit (golden tiles, loot chest); pull
    // the current balance so purchase affordability is accurate.
    widget.engagement.refreshWallet();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<EngagementCubit, EngagementState>(
      bloc: widget.engagement,
      builder: (context, state) {
        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            backgroundColor: AppColors.background,
            foregroundColor: Colors.white,
            title: const Text('Tile Themes'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(child: CoinBalance(coins: state.coins)),
              ),
            ],
          ),
          body: ListView(
            key: const Key('cosmetics-list'),
            padding: const EdgeInsets.all(16),
            children: [
              for (final c in Cosmetic.values)
                _CosmeticTile(
                  cosmetic: c,
                  selected: state.selectedCosmetic == c,
                  unlocked: state.unlockedCosmetics.contains(c),
                  affordable: state.coins >= c.price,
                  onSelect: () => widget.engagement.selectCosmetic(c),
                  onUnlockViaAd: c.unlock == CosmeticUnlock.rewardedAd
                      ? () => _unlockViaAd(context, c)
                      : null,
                  onBuy: c.unlock == CosmeticUnlock.purchase
                      ? () => _buy(context, c)
                      : null,
                ),
            ],
          ),
        );
      },
    );
  }

  void _unlockViaAd(BuildContext context, Cosmetic c) {
    widget.adService.showRewarded(
      onReward: () => widget.engagement.grantAdCosmetic(c),
      onUnavailable: () {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No ad available right now.')),
          );
        }
      },
    );
  }

  Future<void> _buy(BuildContext context, Cosmetic c) async {
    final ok = await widget.engagement.purchaseCosmetic(c);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '${c.label} unlocked!' : 'Not enough coins.'),
      ),
    );
  }
}

class _CosmeticTile extends StatelessWidget {
  final Cosmetic cosmetic;
  final bool selected;
  final bool unlocked;
  final bool affordable;
  final VoidCallback onSelect;
  final VoidCallback? onUnlockViaAd;
  final VoidCallback? onBuy;

  const _CosmeticTile({
    required this.cosmetic,
    required this.selected,
    required this.unlocked,
    required this.affordable,
    required this.onSelect,
    this.onUnlockViaAd,
    this.onBuy,
  });

  String get _unlockHint => switch (cosmetic.unlock) {
        CosmeticUnlock.free => 'Default',
        CosmeticUnlock.streak => 'Reach a ${cosmetic.threshold}-day streak',
        CosmeticUnlock.achievement =>
          'Earn: ${cosmetic.achievement?.label ?? ''}',
        CosmeticUnlock.rewardedAd => 'Watch an ad to unlock',
        CosmeticUnlock.purchase => 'Buy for ${cosmetic.price} coins',
      };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: Key('cosmetic-${cosmetic.name}'),
          borderRadius: BorderRadius.circular(16),
          onTap: unlocked ? onSelect : null,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // Mini color ramp preview (tiers 1..5).
                Row(
                  children: [
                    for (var tier = 1; tier <= 5; tier++)
                      Container(
                        width: 14,
                        height: 28,
                        color: TilePalette.colorFor(cosmetic, tier),
                      ),
                  ],
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(cosmetic.label,
                          style: TextStyle(
                              color: unlocked ? Colors.white : Colors.white54,
                              fontSize: 18,
                              fontWeight: FontWeight.w800)),
                      if (!unlocked)
                        Text(_unlockHint,
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 12)),
                    ],
                  ),
                ),
                if (selected)
                  const Icon(Icons.check_circle, color: Colors.greenAccent)
                else if (!unlocked && onBuy != null)
                  PriceTag(
                    key: Key('cosmetic-buy-${cosmetic.name}'),
                    price: cosmetic.price,
                    affordable: affordable,
                    onBuy: onBuy!,
                  )
                else if (!unlocked && onUnlockViaAd != null)
                  TextButton(
                    key: Key('cosmetic-ad-${cosmetic.name}'),
                    onPressed: onUnlockViaAd,
                    child: const Text('Unlock'),
                  )
                else if (!unlocked)
                  const Icon(Icons.lock_outline, color: Colors.white38),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
