class Wallet {
  final int coins;
  final String? lastLootClaimDate;

  const Wallet({
    this.coins = 0,
    this.lastLootClaimDate,
  });

  Wallet copyWith({
    int? coins,
    String? lastLootClaimDate,
  }) =>
      Wallet(
        coins: coins ?? this.coins,
        lastLootClaimDate: lastLootClaimDate ?? this.lastLootClaimDate,
      );
}
