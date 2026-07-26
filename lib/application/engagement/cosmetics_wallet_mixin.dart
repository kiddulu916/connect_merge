import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/models/avatar.dart';
import '../../domain/models/cosmetic.dart';
import '../../domain/models/difficulty.dart';
import '../../infrastructure/storage_service.dart';
import '../engagement_cubit.dart' show EngagementState, kMaxFreezeTokens;

/// Cosmetics selection/unlocks, the soft-currency wallet, and streak-freeze
/// token banking — split out of [EngagementCubit] for file size. Structural
/// extraction only — no behavior change.
///
/// Split into a separate library (file), so the two members other parts of
/// `EngagementCubit` depend on ([maxTierFreezeTokens] and
/// [consumeOneFreezeToken], used by `load`/`onTierCompleted`, plus the
/// [storage] plumbing) are exposed without a leading underscore — Dart
/// privacy is per-library, so a `_`-prefixed member declared here would be
/// invisible to the main class body in `engagement_cubit.dart`.
mixin CosmeticsWalletMixin on Cubit<EngagementState> {
  /// Provided by [EngagementCubit].
  StorageService get storage;

  bool _grantingFreeze = false;

  /// Select a cosmetic. Gated on the unlocked set — selecting a locked cosmetic
  /// is a no-op (harmless exploit prevention).
  Future<void> selectCosmetic(Cosmetic cosmetic) async {
    if (!state.unlockedCosmetics.contains(cosmetic)) return;
    final profile = storage.loadProfile();
    await storage.saveProfile(profile.selectCosmetic(cosmetic.name));
    emit(state.copyWith(selectedCosmetic: cosmetic));
  }

  /// Grant an ad-unlocked cosmetic (after a rewarded ad). Only valid for
  /// [CosmeticUnlock.rewardedAd] cosmetics.
  Future<void> grantAdCosmetic(Cosmetic cosmetic) async {
    if (cosmetic.unlock != CosmeticUnlock.rewardedAd) return;
    final profile = storage.loadProfile();
    await storage.saveProfile(profile.grantAdCosmetic(cosmetic.name));
    emit(state.copyWith(
      unlockedCosmetics: {...state.unlockedCosmetics, cosmetic},
    ));
  }

  /// Re-sync the wallet balance from storage into state (Phase 2). Coins can be
  /// credited outside this cubit (golden tiles, loot chest), so call this before
  /// gating a purchase so the displayed balance is current. No-op if unchanged.
  void refreshWallet() {
    final coins = storage.loadProfile().wallet.coins;
    if (coins == state.coins) return;
    emit(state.copyWith(coins: coins));
  }

  /// Purchase a [CosmeticUnlock.purchase] cosmetic with coins (Phase 2).
  ///
  /// Read-check-write inside a single [loadProfile]→[saveProfile] so the wallet
  /// cannot leak value:
  /// - rejects non-purchasable cosmetics,
  /// - rejects overspend (`balance < price`) without debiting,
  /// - is idempotent (a cosmetic already purchased is not debited again).
  ///
  /// Returns true only when a fresh purchase was made and committed.
  Future<bool> purchaseCosmetic(Cosmetic cosmetic) async {
    if (cosmetic.unlock != CosmeticUnlock.purchase) return false;
    final profile = storage.loadProfile();
    // Idempotency: already owned -> no debit, no-op.
    if (profile.cosmetics.purchasedCosmetics.contains(cosmetic.name)) {
      return false;
    }
    // Overspend guard: can't afford -> no debit.
    if (profile.wallet.coins < cosmetic.price) return false;

    final newCoins = profile.wallet.coins - cosmetic.price;
    await storage.saveProfile(
      profile.recordPurchase(cosmetic.name, price: cosmetic.price),
    );
    emit(state.copyWith(
      coins: newCoins,
      unlockedCosmetics: {...state.unlockedCosmetics, cosmetic},
    ));
    return true;
  }

  /// Select an avatar. Gated on the unlocked set — selecting a locked avatar is
  /// a no-op. Persists the emoji glyph locally; the CALLER is responsible for
  /// syncing it to the server (`AuthService.updateAvatar`) so it renders on
  /// other players' leaderboards/friends lists — that's the one way avatars
  /// differ from purely-local tile themes.
  Future<void> selectAvatar(Avatar avatar) async {
    if (!state.unlockedAvatars.contains(avatar)) return;
    final profile = storage.loadProfile();
    await storage.saveProfile(profile.selectAvatar(avatar.emoji));
    emit(state.copyWith(selectedAvatar: avatar.emoji));
  }

  /// Seed the locally-cached selected avatar from an external source of truth
  /// (the server profile, read when the avatars screen opens), so the checkmark
  /// matches what other players see. No unlock gate and no server write — this is
  /// a one-way pull, unlike the user-driven [selectAvatar].
  Future<void> syncSelectedAvatar(String emoji) async {
    if (state.selectedAvatar == emoji) return;
    final profile = storage.loadProfile();
    await storage.saveProfile(profile.selectAvatar(emoji));
    emit(state.copyWith(selectedAvatar: emoji));
  }

  /// Purchase a [CosmeticUnlock.purchase] avatar with coins. Same read-check-
  /// write safety as [purchaseCosmetic]: rejects non-purchasable avatars,
  /// overspend (no debit), and is idempotent. Returns true only on a fresh,
  /// committed purchase.
  Future<bool> purchaseAvatar(Avatar avatar) async {
    if (avatar.unlock != CosmeticUnlock.purchase) return false;
    final profile = storage.loadProfile();
    if (profile.avatars.purchasedAvatars.contains(avatar.name)) return false;
    if (profile.wallet.coins < avatar.price) return false;

    final newCoins = profile.wallet.coins - avatar.price;
    await storage.saveProfile(
      profile.recordAvatarPurchase(avatar.name, price: avatar.price),
    );
    emit(state.copyWith(
      coins: newCoins,
      unlockedAvatars: {...state.unlockedAvatars, avatar},
    ));
    return true;
  }

  /// Grant a streak-freeze token (e.g. from a rewarded ad). Banked on every tier
  /// up to [kMaxFreezeTokens] each, so a missed day is shielded regardless of
  /// which tier the player resumes. Returns whether anything was granted.
  Future<bool> grantFreezeToken() async {
    if (_grantingFreeze) return false;
    try {
      _grantingFreeze = true;
      var grantedAny = false;
      for (final d in Difficulty.values) {
        final stats = storage.loadStats(d);
        if (stats.streakFreezeTokens < kMaxFreezeTokens) {
          await storage.saveStats(d,
              stats.copyWith(streakFreezeTokens: stats.streakFreezeTokens + 1));
          grantedAny = true;
        }
      }
      if (grantedAny) {
        emit(state.copyWith(freezeTokens: maxTierFreezeTokens()));
      }
      return grantedAny;
    } finally {
      _grantingFreeze = false;
    }
  }

  // --- helpers ---

  /// The headline freeze-token count = the max banked across any tier (a single
  /// token anywhere can bridge the missed day for the headline streak).
  /// Non-private because `EngagementCubit.load`/`onTierCompleted` — which stay
  /// on the class body in a different file — need it too.
  int maxTierFreezeTokens() {
    var m = 0;
    for (final d in Difficulty.values) {
      final t = storage.loadStats(d).streakFreezeTokens;
      if (t > m) m = t;
    }
    return m;
  }

  /// Consume one freeze token from the tier holding the most (deterministic).
  /// Non-private for the same reason as [maxTierFreezeTokens].
  Future<void> consumeOneFreezeToken() async {
    Difficulty? best;
    var bestCount = 0;
    for (final d in Difficulty.values) {
      final t = storage.loadStats(d).streakFreezeTokens;
      if (t > bestCount) {
        bestCount = t;
        best = d;
      }
    }
    if (best == null || bestCount <= 0) return;
    final stats = storage.loadStats(best);
    await storage.saveStats(
        best, stats.copyWith(streakFreezeTokens: stats.streakFreezeTokens - 1));
  }
}
