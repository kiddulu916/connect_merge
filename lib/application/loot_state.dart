import '../domain/models/loot_reward.dart';

/// UI-facing state of the Daily Loot Chest.
sealed class LootState {
  /// Current wallet balance, surfaced in every state so the UI can show a pill.
  final int coins;
  const LootState(this.coins);
}

/// Today's chest is already claimed (sealed until the next UTC reset).
class LootSealed extends LootState {
  const LootSealed(super.coins);
}

/// Today's chest is unclaimed and ready to open.
class LootReady extends LootState {
  const LootReady(super.coins);
}

/// The chest was just claimed this session, revealing [reward]. [reward.doubled]
/// is true once a rewarded ad has doubled the payout.
class LootClaimed extends LootState {
  final LootReward reward;
  const LootClaimed({required int coins, required this.reward}) : super(coins);
}
