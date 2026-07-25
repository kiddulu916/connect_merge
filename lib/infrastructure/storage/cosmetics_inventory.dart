class CosmeticsInventory {
  final String selectedCosmetic;
  final Set<String> adUnlockedCosmetics;
  final Set<String> purchasedCosmetics;

  const CosmeticsInventory({
    this.selectedCosmetic = 'classic',
    this.adUnlockedCosmetics = const {},
    this.purchasedCosmetics = const {},
  });

  CosmeticsInventory copyWith({
    String? selectedCosmetic,
    Set<String>? adUnlockedCosmetics,
    Set<String>? purchasedCosmetics,
  }) =>
      CosmeticsInventory(
        selectedCosmetic: selectedCosmetic ?? this.selectedCosmetic,
        adUnlockedCosmetics: adUnlockedCosmetics ?? this.adUnlockedCosmetics,
        purchasedCosmetics: purchasedCosmetics ?? this.purchasedCosmetics,
      );
}
