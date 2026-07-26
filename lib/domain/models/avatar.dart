import '../constants.dart';
import 'cosmetic.dart' show CosmeticUnlock;

/// A selectable emoji avatar. Mirrors [Cosmetic]: the enum `name` is the stable
/// storage token for the unlocked/purchased SETS, but the player's *selected*
/// avatar is persisted as the [emoji] glyph itself (backward-compatible with the
/// free-text `players.avatar` column and every surface that renders the glyph —
/// profile, friends list, leaderboard). Emojis must be unique so glyph<->enum is
/// a clean bijection.
///
/// Unlock reuses [CosmeticUnlock] so avatars and tile themes share one model. The
/// current content is `free` (the original eight) or `purchase`; the other unlock
/// kinds are supported by the type but unused, so [isUnlocked] only needs the
/// purchased set.
enum Avatar {
  // --- The original free eight (never gate these; existing players own them). ---
  fox(emoji: '🦊', unlock: CosmeticUnlock.free),
  cat(emoji: '🐱', unlock: CosmeticUnlock.free),
  panda(emoji: '🐼', unlock: CosmeticUnlock.free),
  frog(emoji: '🐸', unlock: CosmeticUnlock.free),
  unicorn(emoji: '🦄', unlock: CosmeticUnlock.free),
  octopus(emoji: '🐙', unlock: CosmeticUnlock.free),
  owl(emoji: '🦉', unlock: CosmeticUnlock.free),
  bee(emoji: '🐝', unlock: CosmeticUnlock.free),

  // --- 20 purchasable (flat [kAvatarPrice]). ---
  wolf(emoji: '🐺', unlock: CosmeticUnlock.purchase, price: kAvatarPrice),
  lion(emoji: '🦁', unlock: CosmeticUnlock.purchase, price: kAvatarPrice),
  tiger(emoji: '🐯', unlock: CosmeticUnlock.purchase, price: kAvatarPrice),
  koala(emoji: '🐨', unlock: CosmeticUnlock.purchase, price: kAvatarPrice),
  penguin(emoji: '🐧', unlock: CosmeticUnlock.purchase, price: kAvatarPrice),
  eagle(emoji: '🦅', unlock: CosmeticUnlock.purchase, price: kAvatarPrice),
  shark(emoji: '🦈', unlock: CosmeticUnlock.purchase, price: kAvatarPrice),
  turtle(emoji: '🐢', unlock: CosmeticUnlock.purchase, price: kAvatarPrice),
  trex(emoji: '🦖', unlock: CosmeticUnlock.purchase, price: kAvatarPrice),
  sauropod(emoji: '🦕', unlock: CosmeticUnlock.purchase, price: kAvatarPrice),
  whale(emoji: '🐳', unlock: CosmeticUnlock.purchase, price: kAvatarPrice),
  seal(emoji: '🦭', unlock: CosmeticUnlock.purchase, price: kAvatarPrice),
  otter(emoji: '🦦', unlock: CosmeticUnlock.purchase, price: kAvatarPrice),
  sloth(emoji: '🦥', unlock: CosmeticUnlock.purchase, price: kAvatarPrice),
  raccoon(emoji: '🦝', unlock: CosmeticUnlock.purchase, price: kAvatarPrice),
  hedgehog(emoji: '🦔', unlock: CosmeticUnlock.purchase, price: kAvatarPrice),
  flamingo(emoji: '🦩', unlock: CosmeticUnlock.purchase, price: kAvatarPrice),
  butterfly(emoji: '🦋', unlock: CosmeticUnlock.purchase, price: kAvatarPrice),
  dragon(emoji: '🐲', unlock: CosmeticUnlock.purchase, price: kAvatarPrice),
  scorpion(emoji: '🦂', unlock: CosmeticUnlock.purchase, price: kAvatarPrice);

  const Avatar({
    required this.emoji,
    required this.unlock,
    this.price = 0,
  });

  /// The rendered glyph. Also the persisted "selected avatar" token.
  final String emoji;

  final CosmeticUnlock unlock;

  /// Coin price for [CosmeticUnlock.purchase] avatars (0 otherwise).
  final int price;

  /// Default avatar (always free) — matches the historical onboarding default.
  static const Avatar defaultAvatar = Avatar.fox;

  /// Resolve an [Avatar] from its [emoji] glyph, or null if unrecognized (e.g. a
  /// legacy value no longer offered).
  static Avatar? byEmoji(String emoji) {
    for (final a in Avatar.values) {
      if (a.emoji == emoji) return a;
    }
    return null;
  }

  /// Pure: is this avatar unlocked? `free` always; `purchase` when its name is in
  /// [purchased]. Other unlock kinds are unused by current content and stay
  /// locked (defensive — add their params here if such avatars are introduced).
  bool isUnlocked({required Set<Avatar> purchased}) {
    switch (unlock) {
      case CosmeticUnlock.free:
        return true;
      case CosmeticUnlock.purchase:
        return purchased.contains(this);
      case CosmeticUnlock.streak:
      case CosmeticUnlock.achievement:
      case CosmeticUnlock.rewardedAd:
        return false;
    }
  }
}

/// The full set of unlocked avatars (pure). Always includes the free ones.
Set<Avatar> unlockedAvatars({Set<Avatar> purchased = const {}}) => Avatar.values
    .where((a) => a.isUnlocked(purchased: purchased))
    .toSet();
