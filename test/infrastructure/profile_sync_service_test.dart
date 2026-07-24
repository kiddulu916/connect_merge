import 'dart:async';

import 'package:connect_merge/domain/models/day_result.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/infrastructure/profile_sync_service.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

DayResult _result(String date) => DayResult(
      date: date,
      difficulty: Difficulty.challenge,
      score: 123,
      highestTier: 7,
      endedOutOfMoves: true,
    );

Map<String, dynamic> _snapshot({int coins = 42}) => {
      'schema_version': 1,
      'profile': PlayerProfile(wallet: Wallet(coins: coins)).toJson(),
      'stats': {
        for (final difficulty in Difficulty.values)
          difficulty.name: LifetimeStats.empty.toJson(),
      },
      'history': [_result('2026-07-20').toJson()],
    };

void main() {
  test('collect and restore round-trip exactly the durable account families',
      () async {
    final source = InMemoryStorageService();
    await source.saveProfile(const PlayerProfile(wallet: Wallet(coins: 42)));
    for (final difficulty in Difficulty.values) {
      await source.saveStats(
        difficulty,
        LifetimeStats(
          streak: difficulty.index + 1,
          lastCompletedDate: '2026-07-20',
          bestScore: 100 + difficulty.index,
          bestTier: 5,
        ),
      );
    }
    await source.appendResult(_result('2026-07-20'));

    final payload = ProfileSyncService.collect(source);
    expect(payload.keys,
        unorderedEquals(['schema_version', 'profile', 'stats', 'history']));
    expect((payload['stats'] as Map).keys,
        unorderedEquals(Difficulty.values.map((d) => d.name)));

    final target = InMemoryStorageService(currentUserId: () => 'player-1');
    final sync = ProfileSyncService.withSeams(
      storage: target,
      currentUid: () => 'player-1',
      rpc: (_, __) async => null,
    );
    expect(await sync.restore(payload, serverRevision: 9),
        SnapshotOutcome.restored);
    expect(target.loadProfile().wallet.coins, 42);
    expect(target.loadStats(Difficulty.challenge).streak, 5);
    expect(target.loadHistory(), [_result('2026-07-20')]);
    expect(
      target.owner,
      const LocalOwner(
        uid: 'player-1',
        snapshotRevision: 9,
        restoreComplete: true,
        recoveryRequired: false,
        // A restore only ever follows a successful claim.
        claimed: true,
      ),
    );
  });

  test('restore validation outcomes stay distinct and preserve live data',
      () async {
    Future<void> expectInvalid(
      Map<String, dynamic> payload,
      SnapshotOutcome expected,
    ) async {
      final storage = InMemoryStorageService(
        currentUserId: () => 'player-1',
      );
      await storage.rebindOwner('player-1', snapshotRevision: 2);
      await storage.saveProfile(
        const PlayerProfile(wallet: Wallet(coins: 7)),
      );
      final sync = ProfileSyncService.withSeams(
        storage: storage,
        currentUid: () => 'player-1',
        rpc: (_, __) async => fail('invalid restore must not call an RPC'),
      );
      expect(await sync.restore(payload, serverRevision: 4), expected);
      expect(storage.loadProfile().wallet.coins, 7);
      expect(storage.owner!.recoveryRequired, isTrue);
      expect(sync.isArmed, isFalse);
    }

    final corrupt = _snapshot();
    (corrupt['stats'] as Map<String, dynamic>).remove('challenge');
    await expectInvalid(corrupt, SnapshotOutcome.corrupt);
    await expectInvalid(
      _snapshot()..['schema_version'] = 2,
      SnapshotOutcome.newerVersion,
    );
    await expectInvalid(
      _snapshot()
        ..['padding'] = List.filled(kMaxProfileSnapshotBytes, 'x').join(),
      SnapshotOutcome.oversized,
    );
  });

  test('claim distinguishes missing row, empty snapshot, and restored snapshot',
      () async {
    Future<({ProfileSyncService sync, InMemoryStorageService storage})> setup(
      dynamic claimResponse,
    ) async {
      var uid = 'guest-user';
      final storage = InMemoryStorageService(currentUserId: () => uid);
      await storage.rebindOwner('guest-user', snapshotRevision: 1);
      await storage.saveProfile(
        const PlayerProfile(wallet: Wallet(coins: 99)),
      );
      uid = 'cloud-user';
      return (
        storage: storage,
        sync: ProfileSyncService.withSeams(
          storage: storage,
          currentUid: () => uid,
          rpc: (function, params) async {
            expect(function, 'claim_profile');
            expect(params['p_device'], storage.deviceId);
            return claimResponse;
          },
        ),
      );
    }

    final missing = await setup(<dynamic>[]);
    expect(
        await missing.sync.claimAndRestore(), SnapshotOutcome.missingPlayerRow);
    expect(missing.storage.loadProfile().wallet.coins, 99);
    expect(missing.sync.isArmed, isFalse);

    final empty = await setup([
      {'profile_snapshot': null, 'snapshot_revision': 0},
    ]);
    expect(await empty.sync.claimAndRestore(), SnapshotOutcome.emptySnapshot);
    expect(empty.storage.loadProfile(), PlayerProfile.empty);
    expect(empty.storage.owner!.uid, 'cloud-user');
    expect(empty.sync.isArmed, isTrue);

    final restored = await setup([
      {'profile_snapshot': _snapshot(coins: 55), 'snapshot_revision': 8},
    ]);
    expect(await restored.sync.claimAndRestore(), SnapshotOutcome.restored);
    expect(restored.storage.loadProfile().wallet.coins, 55);
    expect(restored.storage.owner!.snapshotRevision, 8);
    expect(restored.sync.isArmed, isTrue);
  });

  test('same-uid initial claim pushes local data instead of wiping it',
      () async {
    final calls = <String>[];
    final storage = InMemoryStorageService(
      currentUserId: () => 'guest-user',
    );
    await storage.rebindOwner('guest-user');
    await storage.saveProfile(
      const PlayerProfile(wallet: Wallet(coins: 31)),
    );
    final sync = ProfileSyncService.withSeams(
      storage: storage,
      currentUid: () => 'guest-user',
      rpc: (function, params) async {
        calls.add(function);
        if (function == 'claim_profile') {
          return [
            {'profile_snapshot': null, 'snapshot_revision': 0},
          ];
        }
        expect(
          ((params['p_snapshot'] as Map)['profile'] as Map)['coins'],
          31,
        );
        return true;
      },
    );
    expect(await sync.claimAndPushLocal(), SnapshotOutcome.restored);
    expect(storage.loadProfile().wallet.coins, 31);
    expect(calls, ['claim_profile', 'push_profile']);
    expect(storage.isDirty, isFalse);
  });

  test('failed initial link push remains pending even when local is clean',
      () async {
    var pushes = 0;
    final storage = InMemoryStorageService(
      currentUserId: () => 'guest-user',
    );
    await storage.rebindOwner('guest-user');
    final sync = ProfileSyncService.withSeams(
      storage: storage,
      currentUid: () => 'guest-user',
      rpc: (function, _) async {
        if (function == 'claim_profile') {
          return [
            {'profile_snapshot': null, 'snapshot_revision': 0},
          ];
        }
        pushes++;
        if (pushes == 1) throw StateError('offline');
        return true;
      },
    );

    expect(await sync.claimAndPushLocal(), SnapshotOutcome.pushFailed);
    expect(storage.isDirty, isFalse);
    expect(await sync.flush(), ProfilePushOutcome.pushed);
    expect(pushes, 2);
  });

  test('restore does not self-push and false push supersedes the session',
      () async {
    var pushes = 0;
    var supersededEvents = 0;
    final storage = InMemoryStorageService(
      currentUserId: () => 'player-1',
    );
    await storage.rebindOwner('player-1', claimed: true);
    final sync = ProfileSyncService.withSeams(
      storage: storage,
      currentUid: () => 'player-1',
      debounce: const Duration(days: 1),
      onSuperseded: () => supersededEvents++,
      rpc: (function, _) async {
        expect(function, 'push_profile');
        pushes++;
        return false;
      },
    );
    expect(await sync.restore(_snapshot(), serverRevision: 2),
        SnapshotOutcome.restored);
    expect(pushes, 0);
    sync.arm();
    await storage.saveProfile(
      const PlayerProfile(wallet: Wallet(coins: 9)),
    );
    expect(await sync.flush(), ProfilePushOutcome.superseded);
    expect(sync.isSuperseded, isTrue);
    expect(sync.isArmed, isFalse);
    expect(supersededEvents, 1);
    await storage.addCoins(1);
    expect(await sync.flush(), ProfilePushOutcome.superseded);
    expect(pushes, 1);
  });

  test('pauseAndDrain waits for an in-flight old-account push and disarms',
      () async {
    var uid = 'guest-user';
    var pushes = 0;
    final response = Completer<dynamic>();
    final storage = InMemoryStorageService(currentUserId: () => uid);
    await storage.rebindOwner(uid, claimed: true);
    final sync = ProfileSyncService.withSeams(
      storage: storage,
      currentUid: () => uid,
      debounce: const Duration(days: 1),
      rpc: (function, _) {
        expect(function, 'push_profile');
        pushes++;
        return response.future;
      },
    )..arm();
    await storage.saveProfile(
      const PlayerProfile(wallet: Wallet(coins: 5)),
    );
    final push = sync.pushNow();
    final drain = sync.pauseAndDrain();
    var drained = false;
    drain.then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);

    response.complete(true);
    expect(await push, ProfilePushOutcome.pushed);
    await drain;
    uid = 'cloud-user';
    await storage.rebindOwner(uid, claimed: true);
    await storage.saveProfile(
      const PlayerProfile(wallet: Wallet(coins: 8)),
    );
    await Future<void>.delayed(Duration.zero);
    expect(pushes, 1);
    expect(sync.isArmed, isFalse);
    expect(sync.isSuperseded, isFalse);
  });

  test('flush repeats when a local write lands during an upload', () async {
    final firstResponse = Completer<dynamic>();
    final uploadedCoins = <int>[];
    final storage = InMemoryStorageService(
      currentUserId: () => 'player-1',
    );
    await storage.rebindOwner('player-1', claimed: true);
    final sync = ProfileSyncService.withSeams(
      storage: storage,
      currentUid: () => 'player-1',
      debounce: const Duration(days: 1),
      rpc: (_, params) {
        final profile = (params['p_snapshot'] as Map)['profile'] as Map;
        uploadedCoins.add(profile['coins'] as int);
        if (uploadedCoins.length == 1) return firstResponse.future;
        return Future<dynamic>.value(true);
      },
    )..arm();
    await storage.saveProfile(
      const PlayerProfile(wallet: Wallet(coins: 1)),
    );

    final flush = sync.flush();
    await Future<void>.delayed(Duration.zero);
    await storage.saveProfile(
      const PlayerProfile(wallet: Wallet(coins: 2)),
    );
    firstResponse.complete(true);

    expect(await flush, ProfilePushOutcome.pushed);
    expect(uploadedCoins, [1, 2]);
    expect(storage.isDirty, isFalse);
  });

  test('arm requires a complete matching owner', () async {
    var uid = 'player-1';
    final storage = InMemoryStorageService(currentUserId: () => uid);
    await storage.rebindOwner(uid, claimed: true);
    final sync = ProfileSyncService.withSeams(
      storage: storage,
      currentUid: () => uid,
      rpc: (_, __) async => fail('invalid owner must not push'),
    );

    uid = 'player-2';
    sync.arm();
    expect(sync.isArmed, isFalse);
    uid = 'player-1';
    await storage.startRestore(uid, snapshotRevision: 1);
    sync.arm();
    expect(sync.isArmed, isFalse);
  });

  test('debounce coalesces rapid durable writes into the latest snapshot',
      () async {
    final uploadedCoins = <int>[];
    final storage = InMemoryStorageService(
      currentUserId: () => 'player-1',
    );
    await storage.rebindOwner('player-1', claimed: true);
    final sync = ProfileSyncService.withSeams(
      storage: storage,
      currentUid: () => 'player-1',
      debounce: const Duration(milliseconds: 10),
      rpc: (_, params) async {
        final profile = (params['p_snapshot'] as Map)['profile'] as Map;
        uploadedCoins.add(profile['coins'] as int);
        return true;
      },
    )..arm();

    await storage.saveProfile(
      const PlayerProfile(wallet: Wallet(coins: 1)),
    );
    await storage.saveProfile(
      const PlayerProfile(wallet: Wallet(coins: 2)),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(uploadedCoins, [2]);
    expect(storage.isDirty, isFalse);
    sync.dispose();
  });

  test('push failures retain dirty state for a later retry', () async {
    final storage = InMemoryStorageService(
      currentUserId: () => 'player-1',
    );
    await storage.rebindOwner('player-1', claimed: true);
    var attempts = 0;
    final sync = ProfileSyncService.withSeams(
      storage: storage,
      currentUid: () => 'player-1',
      debounce: const Duration(days: 1),
      rpc: (_, __) async {
        attempts++;
        throw StateError('offline');
      },
    )..arm();
    await storage.addCoins(1);

    expect(await sync.flush(), ProfilePushOutcome.failed);
    expect(storage.isDirty, isTrue);
    expect(sync.isArmed, isTrue);
    expect(attempts, 1);
  });

  test('same-uid crash after promotion is recovered from incomplete owner',
      () async {
    final storage = _CrashAfterPromotionStorage(
      currentUserId: () => 'player-1',
    );
    await storage.rebindOwner('player-1', claimed: true);
    final crashing = ProfileSyncService.withSeams(
      storage: storage,
      currentUid: () => 'player-1',
      rpc: (_, __) async => fail('direct restore must not claim'),
    );
    await expectLater(
      crashing.restore(_snapshot(coins: 30), serverRevision: 2),
      throwsStateError,
    );
    expect(storage.owner!.restoreComplete, isFalse);

    final recovered = ProfileSyncService.withSeams(
      storage: storage,
      currentUid: () => 'player-1',
      rpc: (_, __) async => [
        {'profile_snapshot': _snapshot(coins: 70), 'snapshot_revision': 3},
      ],
    );
    expect(
      await recovered.bootstrap(hasGoogleIdentity: true),
      BootstrapOutcome.restored,
    );
    expect(storage.owner!.restoreComplete, isTrue);
    expect(storage.loadProfile().wallet.coins, 70);
  });

  group('bootstrap ownership table', () {
    test('corrupt owner record remains blocked', () async {
      final storage = _CorruptOwnerStorage(
        currentUserId: () => 'player-1',
      );
      final sync = ProfileSyncService.withSeams(
        storage: storage,
        currentUid: () => 'player-1',
        rpc: (_, __) async => fail('corrupt owner must not claim implicitly'),
      );

      expect(
        await sync.bootstrap(hasGoogleIdentity: true),
        BootstrapOutcome.blockedRecovery,
      );
      expect(sync.isArmed, isFalse);
    });

    test('matching Google owner does not silently reclaim another device',
        () async {
      final storage = InMemoryStorageService(
        currentUserId: () => 'player-1',
      );
      await storage.rebindOwner('player-1', claimed: true);
      final sync = ProfileSyncService.withSeams(
        storage: storage,
        currentUid: () => 'player-1',
        rpc: (_, __) async => fail('matching launch must not reclaim'),
      );

      expect(
        await sync.bootstrap(hasGoogleIdentity: true),
        BootstrapOutcome.ready,
      );
      expect(storage.owner!.snapshotRevision, 0);
      expect(sync.isArmed, isTrue);
    });

    test('pre-feature install claims before arming and its push is accepted',
        () async {
      final online = InMemoryStorageService(currentUserId: () => 'player-1');
      await online.saveProfile(
        const PlayerProfile(wallet: Wallet(coins: 20)),
      );
      String? activeDevice;
      final calls = <String>[];
      final onlineSync = ProfileSyncService.withSeams(
        storage: online,
        currentUid: () => 'player-1',
        debounce: const Duration(days: 1),
        rpc: (function, params) async {
          calls.add(function);
          if (function == 'claim_profile') {
            activeDevice = params['p_device'] as String;
            return [
              {'profile_snapshot': null, 'snapshot_revision': 0},
            ];
          }
          return activeDevice == params['p_device'];
        },
      );
      expect(await onlineSync.bootstrap(hasGoogleIdentity: false),
          BootstrapOutcome.ready);
      expect(online.owner!.uid, 'player-1');
      expect(online.owner!.claimed, isTrue);
      expect(onlineSync.isArmed, isTrue);
      expect(calls, ['claim_profile', 'push_profile']);

      await online.saveProfile(
        const PlayerProfile(wallet: Wallet(coins: 21)),
      );
      expect(await onlineSync.pushNow(), ProfilePushOutcome.pushed);
      expect(onlineSync.isSuperseded, isFalse);

      final offline = InMemoryStorageService();
      final offlineSync = ProfileSyncService.withSeams(
        storage: offline,
        currentUid: () => null,
        rpc: (_, __) async => fail('offline bootstrap must not call RPC'),
      );
      expect(await offlineSync.bootstrap(hasGoogleIdentity: false),
          BootstrapOutcome.offlineReady);
      await offline.saveProfile(
        const PlayerProfile(wallet: Wallet(coins: 1)),
      );
    });

    test('failed first bind claim stays disarmed and retries next bootstrap',
        () async {
      final storage = InMemoryStorageService(
        currentUserId: () => 'player-1',
      );
      var claimAttempts = 0;
      final first = ProfileSyncService.withSeams(
        storage: storage,
        currentUid: () => 'player-1',
        rpc: (function, _) async {
          expect(function, 'claim_profile');
          claimAttempts++;
          throw StateError('offline');
        },
      );

      expect(await first.bootstrap(hasGoogleIdentity: false),
          BootstrapOutcome.offlineReady);
      expect(storage.owner!.claimed, isFalse);
      expect(first.isArmed, isFalse);
      expect(first.isSuperseded, isFalse);
      expect(claimAttempts, 1);

      final calls = <String>[];
      final second = ProfileSyncService.withSeams(
        storage: storage,
        currentUid: () => 'player-1',
        rpc: (function, _) async {
          calls.add(function);
          if (function == 'claim_profile') {
            return [
              {'profile_snapshot': null, 'snapshot_revision': 0},
            ];
          }
          return true;
        },
      );
      expect(await second.bootstrap(hasGoogleIdentity: false),
          BootstrapOutcome.ready);
      expect(storage.owner!.claimed, isTrue);
      expect(second.isArmed, isTrue);
      expect(calls, ['claim_profile', 'push_profile']);
    });

    test('never-claimed install cannot report superseded', () async {
      final storage = InMemoryStorageService(
        currentUserId: () => 'player-1',
      );
      var supersededEvents = 0;
      final sync = ProfileSyncService.withSeams(
        storage: storage,
        currentUid: () => 'player-1',
        debounce: const Duration(days: 1),
        onSuperseded: () => supersededEvents++,
        rpc: (_, __) async => throw StateError('offline'),
      );

      expect(await sync.bootstrap(hasGoogleIdentity: false),
          BootstrapOutcome.offlineReady);
      expect(storage.owner!.claimed, isFalse);
      sync.arm();
      await storage.saveProfile(
        const PlayerProfile(wallet: Wallet(coins: 1)),
      );
      expect(await sync.pushNow(), ProfilePushOutcome.clean);
      expect(sync.isArmed, isFalse);
      expect(sync.isSuperseded, isFalse);
      expect(supersededEvents, 0);
    });

    test('matching owner arms; owner with no session stays offline playable',
        () async {
      final matching = InMemoryStorageService(currentUserId: () => 'player-1');
      await matching.rebindOwner('player-1', claimed: true);
      final matchingSync = ProfileSyncService.withSeams(
        storage: matching,
        currentUid: () => 'player-1',
        rpc: (_, __) async => fail('matching bootstrap must not claim'),
      );
      expect(await matchingSync.bootstrap(hasGoogleIdentity: false),
          BootstrapOutcome.ready);
      expect(matchingSync.isArmed, isTrue);

      final offline = InMemoryStorageService();
      await offline.rebindOwner('player-1');
      final offlineSync = ProfileSyncService.withSeams(
        storage: offline,
        currentUid: () => null,
        rpc: (_, __) async => fail('offline bootstrap must not call RPC'),
      );
      expect(await offlineSync.bootstrap(hasGoogleIdentity: false),
          BootstrapOutcome.offlineReady);
      await offline.addCoins(1);
    });

    test('anonymous mismatch wipes, rebinds, and requests the gate', () async {
      var uid = 'old-user';
      final storage = InMemoryStorageService(currentUserId: () => uid);
      await storage.rebindOwner('old-user');
      await storage.saveProfile(
        const PlayerProfile(wallet: Wallet(coins: 20)),
      );
      uid = 'new-guest';
      final sync = ProfileSyncService.withSeams(
        storage: storage,
        currentUid: () => uid,
        rpc: (_, __) async => fail('anonymous recovery must not claim'),
      );
      expect(await sync.bootstrap(hasGoogleIdentity: false),
          BootstrapOutcome.needsAuthGate);
      expect(storage.owner!.uid, 'new-guest');
      expect(storage.loadProfile(), PlayerProfile.empty);
    });

    test('Google mismatch and interrupted restore claim and restore', () async {
      for (final interrupted in [false, true]) {
        final storage = InMemoryStorageService(
          currentUserId: () => 'cloud-user',
        );
        await storage.rebindOwner('guest-user');
        if (interrupted) {
          await storage.startRestore('cloud-user', snapshotRevision: 1);
        }
        final sync = ProfileSyncService.withSeams(
          storage: storage,
          currentUid: () => 'cloud-user',
          rpc: (_, __) async => [
            {
              'profile_snapshot': _snapshot(coins: 88),
              'snapshot_revision': 6,
            },
          ],
        );
        expect(await sync.bootstrap(hasGoogleIdentity: true),
            BootstrapOutcome.restored);
        expect(storage.loadProfile().wallet.coins, 88);
        expect(storage.owner!.restoreComplete, isTrue);
      }
    });

    test('same-uid interrupted anonymous restore is retried', () async {
      final storage = InMemoryStorageService(
        currentUserId: () => 'player-1',
      );
      await storage.rebindOwner('player-1', claimed: true);
      await storage.startRestore('player-1', snapshotRevision: 2);
      final sync = ProfileSyncService.withSeams(
        storage: storage,
        currentUid: () => 'player-1',
        rpc: (_, __) async => [
          {
            'profile_snapshot': _snapshot(coins: 77),
            'snapshot_revision': 3,
          },
        ],
      );

      expect(await sync.bootstrap(hasGoogleIdentity: false),
          BootstrapOutcome.restored);
      expect(storage.loadProfile().wallet.coins, 77);
      expect(storage.owner!.restoreComplete, isTrue);
    });

    test('malformed claimed snapshot becomes a persisted recovery block',
        () async {
      final storage = InMemoryStorageService(
        currentUserId: () => 'player-1',
      );
      await storage.rebindOwner('player-1', claimed: true);
      final sync = ProfileSyncService.withSeams(
        storage: storage,
        currentUid: () => 'player-1',
        rpc: (_, __) async => [
          {'profile_snapshot': 'not-json-object', 'snapshot_revision': 4},
        ],
      );

      expect(await sync.claimAndRestore(), SnapshotOutcome.corrupt);
      expect(storage.owner!.recoveryRequired, isTrue);
      expect(sync.isArmed, isFalse);
    });

    test('recovery-required and interrupted-offline installs stay blocked',
        () async {
      final recovery = InMemoryStorageService(currentUserId: () => 'player-1');
      await recovery.rebindOwner('player-1');
      await recovery.markRecoveryRequired('player-1', snapshotRevision: 2);
      final recoverySync = ProfileSyncService.withSeams(
        storage: recovery,
        currentUid: () => 'player-1',
        rpc: (_, __) async => fail('blocked recovery must wait for retry'),
      );
      expect(await recoverySync.bootstrap(hasGoogleIdentity: true),
          BootstrapOutcome.blockedRecovery);

      final interrupted = InMemoryStorageService();
      await interrupted.rebindOwner('player-1');
      await interrupted.startRestore('player-1', snapshotRevision: 2);
      final interruptedSync = ProfileSyncService.withSeams(
        storage: interrupted,
        currentUid: () => null,
        rpc: (_, __) async => fail('offline interrupted must not call RPC'),
      );
      expect(await interruptedSync.bootstrap(hasGoogleIdentity: true),
          BootstrapOutcome.blockedInterruptedRestore);
    });
  });
}

class _CrashAfterPromotionStorage extends InMemoryStorageService {
  bool _crashOnce = true;

  _CrashAfterPromotionStorage({required super.currentUserId});

  @override
  Future<void> promoteStagedRestore() async {
    await super.promoteStagedRestore();
    if (_crashOnce) {
      _crashOnce = false;
      throw StateError('simulated process death after promotion');
    }
  }
}

class _CorruptOwnerStorage extends InMemoryStorageService {
  _CorruptOwnerStorage({required super.currentUserId});

  @override
  bool get ownerRecordCorrupt => true;
}
