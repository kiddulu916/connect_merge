import 'dart:io';

import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/infrastructure/hive_storage_service.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  setUp(() {
    Hive.init(
      '${Directory.systemTemp.path}/connect_merge_owner_'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
  });

  tearDown(() async => Hive.deleteFromDisk());

  test('payload and dirty revision survive reopening together', () async {
    final first = HiveStorageService();
    await first.init();
    await first.saveProfile(
      const PlayerProfile(wallet: Wallet(coins: 17)),
    );
    final revision = first.localRevision;

    final reopened = HiveStorageService();
    await reopened.init();

    expect(reopened.loadProfile().wallet.coins, 17);
    expect(reopened.localRevision, revision);
    expect(reopened.isDirty, isTrue);
  });

  test('interrupted same-uid promotion remains blocked after reopening',
      () async {
    final first = HiveStorageService(currentUserId: () => 'account-a');
    await first.init();
    await first.rebindOwner('account-a', snapshotRevision: 1);
    await first.startRestore('account-a', snapshotRevision: 2);
    await first.stageRestore(
      profile: const PlayerProfile(wallet: Wallet(coins: 22)),
      stats: {
        for (final difficulty in Difficulty.values)
          difficulty: LifetimeStats.empty,
      },
      history: const [],
    );
    await first.promoteStagedRestore();

    final reopened = HiveStorageService(currentUserId: () => 'account-a');
    await reopened.init();

    expect(reopened.owner!.restoreComplete, isFalse);
    await expectLater(
      reopened.saveProfile(const PlayerProfile(wallet: Wallet(coins: 23))),
      throwsA(isA<StorageWriteBlockedException>()),
    );
  });

  test('device id and revisions survive account-only wipe', () async {
    final storage = HiveStorageService();
    await storage.init();
    await storage.rebindOwner('account-a', snapshotRevision: 1);
    await storage.saveStats(
        Difficulty.easy,
        const LifetimeStats(
          streak: 1,
          lastCompletedDate: '2026-07-20',
          bestScore: 1,
          bestTier: 1,
        ));
    final deviceId = storage.deviceId;
    final revision = storage.localRevision;

    await storage.wipeAccountData();

    expect(storage.deviceId, deviceId);
    expect(storage.localRevision, revision);
    expect(storage.owner!.uid, 'account-a');
    expect(storage.loadStats(Difficulty.easy), LifetimeStats.empty);
  });

  test('claim state survives reopening and legacy owners retry safely',
      () async {
    final storage = HiveStorageService();
    await storage.init();
    await storage.rebindOwner('account-a');

    final unclaimed = HiveStorageService();
    await unclaimed.init();
    expect(unclaimed.owner!.claimed, isFalse);

    await unclaimed.recordClaim('account-a', snapshotRevision: 4);
    final claimed = HiveStorageService();
    await claimed.init();
    expect(claimed.owner!.claimed, isTrue);

    await Hive.box<String>('connect_merge').put(
      'owner',
      '{"uid":"account-a","snapshot_revision":4,'
          '"restore_complete":true,"recovery_required":false}',
    );
    expect(claimed.owner!.claimed, isFalse);
  });

  test('malformed owner bytes block writes instead of impersonating absence',
      () async {
    final storage = HiveStorageService(currentUserId: () => 'account-a');
    await storage.init();
    await Hive.box<String>('connect_merge').put('owner', '{broken-json');

    expect(storage.owner, isNull);
    expect(storage.ownerRecordCorrupt, isTrue);
    await expectLater(
      storage.addCoins(1),
      throwsA(isA<StorageWriteBlockedException>()),
    );
  });
}
