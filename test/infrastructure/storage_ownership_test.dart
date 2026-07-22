import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:connect_merge/domain/models/day_result.dart';
import 'package:connect_merge/domain/models/difficulty.dart';

void main() {
  test('absent owner is writable but an authenticated mismatch is rejected',
      () async {
    var sessionUid = 'account-a';
    final storage = InMemoryStorageService(currentUserId: () => sessionUid);

    await storage.saveProfile(const PlayerProfile(wallet: Wallet(coins: 10)));
    await storage.rebindOwner('account-a', snapshotRevision: 3);
    sessionUid = 'account-b';

    await expectLater(
      storage.saveProfile(const PlayerProfile(wallet: Wallet(coins: 99))),
      throwsA(isA<StorageWriteBlockedException>()),
    );
    expect(storage.loadProfile().wallet.coins, 10);
  });

  test('offline owner stays writable while recovery and restore block writes',
      () async {
    final storage = InMemoryStorageService();
    await storage.rebindOwner('account-a', snapshotRevision: 1);
    await storage.saveProfile(const PlayerProfile(wallet: Wallet(coins: 1)));

    await storage.startRestore('account-a', snapshotRevision: 2);
    await expectLater(
      storage.saveProfile(const PlayerProfile(wallet: Wallet(coins: 2))),
      throwsA(isA<StorageWriteBlockedException>()),
    );

    await storage.finishRestore('account-a', snapshotRevision: 2);
    await storage.markRecoveryRequired('account-a', snapshotRevision: 2);
    await expectLater(
      storage.saveProfile(const PlayerProfile(wallet: Wallet(coins: 3))),
      throwsA(isA<StorageWriteBlockedException>()),
    );

    await storage.rebindOwner('account-a', snapshotRevision: 3);
    expect(storage.owner!.recoveryRequired, isFalse);
    await storage.saveProfile(const PlayerProfile(wallet: Wallet(coins: 4)));
    expect(storage.loadProfile().wallet.coins, 4);
  });

  test('dirty revision does not clear when a write lands during an upload',
      () async {
    var changes = 0;
    final storage = InMemoryStorageService(onChanged: () => changes++);
    await storage.rebindOwner('account-a', snapshotRevision: 0);

    await storage.saveProfile(const PlayerProfile(wallet: Wallet(coins: 1)));
    final uploadedRevision = storage.captureRevision();
    await storage.addCoins(1);

    expect(await storage.markPushed(uploadedRevision), isFalse);
    expect(storage.isDirty, isTrue);
    expect(storage.syncedRevision, uploadedRevision);
    expect(storage.owner!.snapshotRevision, 1);
    expect(changes, 2);

    expect(await storage.markPushed(storage.captureRevision()), isTrue);
    expect(storage.isDirty, isFalse);
  });

  test('restore promotes every tier without marking the restored data dirty',
      () async {
    var changes = 0;
    final storage = InMemoryStorageService(
      currentUserId: () => 'account-a',
      onChanged: () => changes++,
    );
    final stats = {
      for (final difficulty in Difficulty.values)
        difficulty: LifetimeStats(
          streak: difficulty.index + 1,
          lastCompletedDate: '2026-07-20',
          bestScore: difficulty.index * 100,
          bestTier: difficulty.index,
        ),
    };
    const history = [
      DayResult(
        date: '2026-07-20',
        difficulty: Difficulty.challenge,
        score: 123,
        highestTier: 7,
        endedOutOfMoves: true,
      ),
    ];

    await storage.startRestore('account-a', snapshotRevision: 8);
    await storage.stageRestore(
      profile: const PlayerProfile(wallet: Wallet(coins: 42)),
      stats: stats,
      history: history,
    );
    await storage.promoteStagedRestore();

    expect(storage.owner!.restoreComplete, isFalse);
    expect(changes, 0);
    for (final difficulty in Difficulty.values) {
      expect(storage.loadStats(difficulty), stats[difficulty]);
    }
    expect(storage.loadHistory(), history);

    await storage.finishRestore('account-a', snapshotRevision: 8);
    expect(storage.owner!.restoreComplete, isTrue);
    expect(storage.isDirty, isFalse);
  });

  test('wipeAccountData preserves install state and clears account snapshots',
      () async {
    final storage = InMemoryStorageService();
    await storage.init();
    await storage.rebindOwner('account-a', snapshotRevision: 4);
    final deviceId = storage.deviceId;
    await storage.saveProfile(const PlayerProfile(wallet: Wallet(coins: 9)));
    await storage.saveStats(
      Difficulty.challenge,
      const LifetimeStats(
        streak: 1,
        lastCompletedDate: '2026-07-20',
        bestScore: 9,
        bestTier: 2,
      ),
    );
    await storage.appendResult(const DayResult(
      date: '2026-07-20',
      difficulty: Difficulty.easy,
      score: 9,
      highestTier: 2,
      endedOutOfMoves: true,
    ));

    await storage.wipeAccountData();

    expect(storage.deviceId, deviceId);
    expect(storage.owner!.uid, 'account-a');
    expect(storage.localRevision, greaterThan(0));
    expect(storage.loadProfile(), PlayerProfile.empty);
    expect(storage.loadStats(Difficulty.challenge), LifetimeStats.empty);
    expect(storage.loadHistory(), isEmpty);
  });

  test('recovery required clears only on restore or rebind', () async {
    final storage = InMemoryStorageService();
    await storage.rebindOwner('account-a');
    await storage.markRecoveryRequired('account-a', snapshotRevision: 2);

    expect(storage.owner!.recoveryRequired, isTrue);
    await storage.init();
    expect(storage.owner!.recoveryRequired, isTrue);

    await storage.rebindOwner('account-a', snapshotRevision: 3);
    expect(storage.owner!.recoveryRequired, isFalse);
  });
}
