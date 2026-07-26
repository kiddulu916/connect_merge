import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../application/loot_cubit.dart';
import '../../../application/loot_state.dart';
import '../../theme/tokens.dart';
import '../../widgets/coin_balance.dart';

/// The daily-chest / coin-balance / leaderboard button row on the tier-select
/// screen. Extracted from tier_select_screen.dart.
class LootLeaderboardRow extends StatelessWidget {
  final LootCubit loot;
  final VoidCallback onOpenLootChest;
  final VoidCallback onOpenLeaderboard;

  const LootLeaderboardRow({
    super.key,
    required this.loot,
    required this.onOpenLootChest,
    required this.onOpenLeaderboard,
  });

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LootCubit, LootState>(
      bloc: loot,
      builder: (context, loot) {
        final ready = loot is LootReady;
        return Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                key: const Key('open-loot-chest'),
                onPressed: onOpenLootChest,
                icon: const Icon(Icons.card_giftcard, size: 18),
                label: Text(ready ? 'Daily chest' : 'Chest claimed',
                    overflow: TextOverflow.ellipsis),
                style: FilledButton.styleFrom(
                  backgroundColor:
                      ready ? AppColors.accent : AppColors.surface,
                  foregroundColor: AppColors.textPrimary,
                  padding:
                      const EdgeInsets.symmetric(vertical: AppSpacing.md),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            CoinBalance(coins: loot.coins),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('open-leaderboard-menu'),
                onPressed: onOpenLeaderboard,
                icon: const Icon(Icons.leaderboard, size: 18),
                label: const Text('Leaderboard',
                    overflow: TextOverflow.ellipsis),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textPrimary,
                  side: const BorderSide(color: AppColors.border),
                  padding:
                      const EdgeInsets.symmetric(vertical: AppSpacing.md),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
