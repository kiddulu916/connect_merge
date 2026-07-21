import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/application/loot_cubit.dart';
import 'package:connect_merge/application/loot_state.dart';
import 'package:connect_merge/domain/engine/daily_loot.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';

void main() {
  late InMemoryStorageService storage;
  LootCubit make(String date) =>
      LootCubit(storage: storage, todayProvider: () => date);

  setUp(() => storage = InMemoryStorageService());

  test('load: fresh profile -> ready', () {
    final c = make('2026-06-11')..load();
    expect(c.state, isA<LootReady>());
    expect(c.state.coins, 0);
  });

  test('load: already claimed today -> sealed', () async {
    await storage.saveProfile(const PlayerProfile(
        wallet: Wallet(
      lastLootClaimDate: '2026-06-11',
      coins: 42,
    )));
    final c = make('2026-06-11')..load();
    expect(c.state, isA<LootSealed>());
    expect(c.state.coins, 42);
  });

  test('claim credits the seed-derived reward and stamps the date', () async {
    final c = make('2026-06-11')..load();
    await c.claim();

    final expected = DailyLoot.forDate('2026-06-11');
    final state = c.state;
    expect(state, isA<LootClaimed>());
    expect((state as LootClaimed).reward, expected);
    expect(state.coins, expected.coins);

    final profile = storage.loadProfile();
    expect(profile.wallet.coins, expected.coins);
    expect(profile.wallet.lastLootClaimDate, '2026-06-11');
  });

  test('claiming twice in one UTC day credits only once', () async {
    final c = make('2026-06-11')..load();
    await c.claim();
    final afterFirst = storage.loadProfile().wallet.coins;
    await c.claim(); // second attempt same day
    expect(storage.loadProfile().wallet.coins, afterFirst);
    expect(c.state, isA<LootSealed>());
  });

  test('resuming the same day after a claim is sealed', () async {
    final c1 = make('2026-06-11')..load();
    await c1.claim();
    final coins = storage.loadProfile().wallet.coins;

    final c2 = make('2026-06-11')..load();
    expect(c2.state, isA<LootSealed>());
    expect(c2.state.coins, coins);
    expect(c2.isClaimable, isFalse);
  });

  test('a new UTC day is claimable again', () async {
    final c1 = make('2026-06-11')..load();
    await c1.claim();

    final c2 = make('2026-06-12')..load();
    expect(c2.state, isA<LootReady>());
    expect(c2.isClaimable, isTrue);
  });

  test('doubleReward credits the same amount again and flags doubled',
      () async {
    final c = make('2026-06-11')..load();
    await c.claim();
    final base = (c.state as LootClaimed).reward.coins;

    await c.doubleReward();
    final state = c.state as LootClaimed;
    expect(state.reward.doubled, isTrue);
    expect(state.reward.coins, base * 2);
    expect(state.coins, base * 2);
    expect(storage.loadProfile().wallet.coins, base * 2);
  });

  test('doubleReward is idempotent (no triple credit)', () async {
    final c = make('2026-06-11')..load();
    await c.claim();
    final base = (c.state as LootClaimed).reward.coins;
    await c.doubleReward();
    await c.doubleReward(); // second call is a no-op
    expect(storage.loadProfile().wallet.coins, base * 2);
  });

  test('overlapping doubleReward callbacks credit once', () async {
    final c = make('2026-06-11')..load();
    await c.claim();
    final base = (c.state as LootClaimed).reward.coins;

    final first = c.doubleReward();
    final second = c.doubleReward();
    await Future.wait([first, second]);

    expect(storage.loadProfile().wallet.coins, base * 2);
  });

  test('doubleReward without a prior claim is a no-op', () async {
    final c = make('2026-06-11')..load();
    await c.doubleReward();
    expect(c.state, isA<LootReady>());
    expect(storage.loadProfile().wallet.coins, 0);
  });

  test('claim accumulates onto an existing wallet balance', () async {
    await storage.saveProfile(const PlayerProfile(wallet: Wallet(coins: 100)));
    final c = make('2026-06-11')..load();
    await c.claim();
    final reward = DailyLoot.forDate('2026-06-11');
    expect(storage.loadProfile().wallet.coins, 100 + reward.coins);
  });
}
