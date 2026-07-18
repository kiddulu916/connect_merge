import 'package:flutter_bloc/flutter_bloc.dart';

import '../domain/engine/daily_loot.dart';
import '../domain/models/loot_reward.dart';
import '../infrastructure/storage_service.dart';
import 'game_cubit.dart' show utcToday;
import 'loot_state.dart';

/// Orchestrates the Daily Loot Chest: whether today's chest is claimable, the
/// claim itself, the optional rewarded-ad "double it", and wallet crediting.
///
/// All reward variance is seed-derived ([DailyLoot.forDate]); this cubit only
/// wires it to [StorageService] persistence and the UI. The wallet is a
/// purely client-side economy — it never touches `BoardState.score`.
class LootCubit extends Cubit<LootState> {
  final StorageService storage;
  final String Function() todayProvider;

  /// The reward revealed by the current claim; retained so [doubleReward] can
  /// credit the same amount again after a rewarded ad.
  LootReward? _claimed;

  LootCubit({
    required this.storage,
    String Function()? todayProvider,
  })  : todayProvider = todayProvider ?? utcToday,
        super(LootSealed(storage.loadProfile().wallet.coins));

  /// Hydrate: ready when today's chest is unclaimed, otherwise sealed.
  void load() {
    final profile = storage.loadProfile();
    final claimable = profile.wallet.lastLootClaimDate != todayProvider();
    emit(claimable
        ? LootReady(profile.wallet.coins)
        : LootSealed(profile.wallet.coins));
  }

  /// Whether today's chest can still be claimed.
  bool get isClaimable =>
      storage.loadProfile().wallet.lastLootClaimDate != todayProvider();

  /// Claim today's chest: compute the seed-derived reward, persist the claim
  /// stamp + credited coins BEFORE emitting (so an app kill mid-claim can't
  /// double-credit), then reveal it. No-op if already claimed today.
  Future<void> claim() async {
    final today = todayProvider();
    final profile = storage.loadProfile();
    if (profile.wallet.lastLootClaimDate == today) {
      emit(LootSealed(profile.wallet.coins));
      return;
    }
    final reward = DailyLoot.forDate(today);
    final coins = profile.wallet.coins + reward.coins;
    await storage.saveProfile(profile.claimLoot(
      today,
      awardCoins: reward.coins,
    ));
    _claimed = reward;
    emit(LootClaimed(coins: coins, reward: reward));
  }

  /// Double the just-claimed reward (call AFTER a rewarded ad grants). Credits
  /// the reward's coins a second time and re-reveals it as doubled. No-op
  /// unless we are in a fresh, not-yet-doubled [LootClaimed] state.
  Future<void> doubleReward() async {
    final s = state;
    final base = _claimed;
    if (s is! LootClaimed || base == null || base.doubled) return;
    final profile = storage.loadProfile();
    final coins = profile.wallet.coins + base.coins; // credit the same amount again
    await storage.saveProfile(profile.creditCoins(base.coins));
    final doubled = base.asDoubled();
    _claimed = doubled;
    emit(LootClaimed(coins: coins, reward: doubled));
  }
}
