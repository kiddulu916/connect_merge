/// Persisted avatar state. Mirrors `CosmeticsInventory`, with one deliberate
/// asymmetry: [selectedAvatar] is the emoji GLYPH (backward-compatible with the
/// free-text `players.avatar` column and every glyph-rendering surface), while
/// [purchasedAvatars] holds Avatar enum `name`s (the stable unlock tokens).
///
/// No ad-unlocked set: current avatar content is only free or coin-purchase.
class AvatarsInventory {
  final String selectedAvatar;
  final Set<String> purchasedAvatars;

  const AvatarsInventory({
    this.selectedAvatar = '🦊',
    this.purchasedAvatars = const {},
  });

  AvatarsInventory copyWith({
    String? selectedAvatar,
    Set<String>? purchasedAvatars,
  }) =>
      AvatarsInventory(
        selectedAvatar: selectedAvatar ?? this.selectedAvatar,
        purchasedAvatars: purchasedAvatars ?? this.purchasedAvatars,
      );
}
