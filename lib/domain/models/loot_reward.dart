/// Immutable result of opening the Daily Loot Chest.
///
/// Purely a client-side economy reward: [coins] credit the wallet on
/// `PlayerProfile`; an optional rare [shardCosmetic] is a cosmetic shard token.
/// [doubled] records that a rewarded ad doubled the coin payout. None of these
/// fields touch `BoardState.score` or the move log — replay fairness is
/// unaffected.
class LootReward {
  final int coins;
  final String? shardCosmetic;
  final bool doubled;

  const LootReward({
    required this.coins,
    this.shardCosmetic,
    this.doubled = false,
  });

  /// The same reward with its coins doubled (the rewarded-ad "double it" path).
  LootReward asDoubled() =>
      LootReward(coins: coins * 2, shardCosmetic: shardCosmetic, doubled: true);

  @override
  bool operator ==(Object other) =>
      other is LootReward &&
      other.coins == coins &&
      other.shardCosmetic == shardCosmetic &&
      other.doubled == doubled;

  @override
  int get hashCode => Object.hash(coins, shardCosmetic, doubled);

  @override
  String toString() =>
      'LootReward(coins: $coins, shardCosmetic: $shardCosmetic, doubled: $doubled)';
}
