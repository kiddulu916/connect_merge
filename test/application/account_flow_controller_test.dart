import 'dart:async';
import 'dart:math';

import 'package:connect_merge/application/account_flow_controller.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/infrastructure/auth_service.dart';
import 'package:connect_merge/infrastructure/profile_sync_service.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('linked crash-resume skips the provider gate and resumes name creation',
      () {
    expect(
      initialAccountRoute(
        bootstrap: BootstrapOutcome.ready,
        needsDisplayName: true,
        hasGoogleIdentity: true,
      ),
      InitialAccountRoute.displayName,
    );
    expect(
      initialAccountRoute(
        bootstrap: BootstrapOutcome.ready,
        needsDisplayName: true,
        hasGoogleIdentity: false,
      ),
      InitialAccountRoute.authGate,
    );
  });

  test('fresh install (no players row, no Google) shows the provider gate', () {
    // A first-run anonymous install has no players row, so bootstrap reports
    // missingPlayerRow. It must reach the gate to choose guest vs Google —
    // NOT be dropped straight into name creation. Regression: verified on a
    // real device where a fresh install skipped the gate entirely.
    expect(
      initialAccountRoute(
        bootstrap: BootstrapOutcome.missingPlayerRow,
        needsDisplayName: true,
        hasGoogleIdentity: false,
      ),
      InitialAccountRoute.authGate,
    );
    // But a player who linked Google and crashed before naming resumes name
    // creation, never the gate (re-picking an account there is destructive).
    expect(
      initialAccountRoute(
        bootstrap: BootstrapOutcome.missingPlayerRow,
        needsDisplayName: true,
        hasGoogleIdentity: true,
      ),
      InitialAccountRoute.displayName,
    );
  });

  test('account work drain blocks adoption until an old-uid write commits',
      () async {
    final tracker = AccountWorkTracker();
    final release = Completer<void>();
    var uid = 'account-a';
    var committedUnder = '';
    tracker.retainAll([
      release.future.then((_) async {
        committedUnder = uid;
      }),
    ]);

    final boundary = () async {
      await tracker.drain();
      uid = 'account-b';
    }();
    await Future<void>.delayed(Duration.zero);
    expect(uid, 'account-a');
    release.complete();
    await boundary;
    expect(committedUnder, 'account-a');
    expect(uid, 'account-b');
  });

  test('guest name retries uniqueness and claims an initial snapshot',
      () async {
    final auth = _FakeAuthService(uid: 'guest-1', takenNames: 2);
    final storage = InMemoryStorageService(currentUserId: () => auth.uid);
    await storage.rebindOwner(auth.uid!);
    var claims = 0;
    var pushes = 0;
    final sync = ProfileSyncService.withSeams(
      storage: storage,
      currentUid: () => auth.uid,
      rpc: (function, _) async {
        if (function == 'claim_profile') {
          claims++;
          return [
            {'profile_snapshot': null, 'snapshot_revision': 0},
          ];
        }
        pushes++;
        return true;
      },
    );
    final controller = AccountFlowController(
      auth: auth,
      storage: storage,
      sync: sync,
      drainAccountWork: () async {},
      reloadLocalState: () async {},
      random: _SequenceRandom([1, 2, 3]),
    );

    await controller.playAsGuest();
    expect(auth.names, ['Player000001', 'Player000002', 'Player000003']);
    expect(claims, 1);
    expect(pushes, 1);
  });

  test('Profile linked outcome claims and initially pushes without name route',
      () async {
    final auth = _FakeAuthService(uid: 'guest-1');
    final storage = InMemoryStorageService(currentUserId: () => auth.uid);
    await storage.rebindOwner(auth.uid!);
    await storage.saveProfile(
      const PlayerProfile(wallet: Wallet(coins: 24)),
    );
    final calls = <String>[];
    final sync = ProfileSyncService.withSeams(
      storage: storage,
      currentUid: () => auth.uid,
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
    final controller = AccountFlowController(
      auth: auth,
      storage: storage,
      sync: sync,
      drainAccountWork: () async {},
      reloadLocalState: () async {},
    );

    expect(
      await controller.beginGoogle(hasDisplayName: true),
      GoogleFlowOutcome.linkedReady,
    );
    expect(calls, ['claim_profile', 'push_profile']);
    expect(storage.loadProfile().wallet.coins, 24);
  });

  test('collision drains old work before adopting and restores cloud',
      () async {
    final events = <String>[];
    late final _FakeAuthService auth;
    auth = _FakeAuthService(
      uid: 'guest-1',
      googleResult: GoogleAuthResult.collision,
      onAdopt: () {
        events.add('adopt');
        auth.uid = 'cloud-1';
      },
    );
    final storage = InMemoryStorageService(currentUserId: () => auth.uid);
    await storage.rebindOwner(auth.uid!);
    final sync = ProfileSyncService.withSeams(
      storage: storage,
      currentUid: () => auth.uid,
      rpc: (function, _) async {
        events.add(function);
        if (function == 'push_profile') return true;
        if (auth.uid == 'guest-1') {
          return [
            {'profile_snapshot': null, 'snapshot_revision': 0},
          ];
        }
        return [
          {'profile_snapshot': _snapshot(coins: 60), 'snapshot_revision': 4},
        ];
      },
    );
    final controller = AccountFlowController(
      auth: auth,
      storage: storage,
      sync: sync,
      drainAccountWork: () async => events.add('drain'),
      reloadLocalState: () async => events.add('reload'),
    );

    expect(
      await controller.beginGoogle(hasDisplayName: true),
      GoogleFlowOutcome.collision,
    );
    expect(await controller.confirmAdopt(), GoogleFlowOutcome.adoptedReady);
    expect(events, [
      'claim_profile',
      'push_profile',
      'drain',
      'adopt',
      'claim_profile',
      'reload',
    ]);
    expect(storage.owner!.uid, 'cloud-1');
    expect(storage.loadProfile().wallet.coins, 60);
  });

  test('missing adopted row stays blocked until name then empty pull wipes',
      () async {
    late final _FakeAuthService auth;
    auth = _FakeAuthService(
      uid: 'guest-1',
      googleResult: GoogleAuthResult.collision,
      onAdopt: () => auth.uid = 'cloud-1',
    );
    final storage = InMemoryStorageService(currentUserId: () => auth.uid);
    await storage.rebindOwner('guest-1');
    await storage.saveProfile(
      const PlayerProfile(wallet: Wallet(coins: 40)),
    );
    var cloudClaims = 0;
    final sync = ProfileSyncService.withSeams(
      storage: storage,
      currentUid: () => auth.uid,
      rpc: (function, _) async {
        if (function == 'push_profile') return true;
        if (auth.uid == 'guest-1') {
          return [
            {'profile_snapshot': null, 'snapshot_revision': 0},
          ];
        }
        cloudClaims++;
        if (cloudClaims == 1) return <dynamic>[];
        return [
          {'profile_snapshot': null, 'snapshot_revision': 0},
        ];
      },
    );
    final controller = AccountFlowController(
      auth: auth,
      storage: storage,
      sync: sync,
      drainAccountWork: () async {},
      reloadLocalState: () async {},
    );

    expect(
      await controller.beginGoogle(hasDisplayName: true),
      GoogleFlowOutcome.collision,
    );
    expect(
      await controller.confirmAdopt(),
      GoogleFlowOutcome.adoptedNeedsDisplayName,
    );
    expect(storage.loadProfile().wallet.coins, 40);
    expect(storage.owner!.uid, 'guest-1');

    await auth.setDisplayName('Cloud player');
    await controller.completeDisplayName();
    expect(storage.loadProfile(), PlayerProfile.empty);
    expect(storage.owner!.uid, 'cloud-1');
  });

  test('existing guest link claims and initially pushes without name routing',
      () async {
    final auth = _FakeAuthService(uid: 'guest-1');
    final storage = InMemoryStorageService(currentUserId: () => auth.uid);
    await storage.rebindOwner(auth.uid!);
    await storage.saveProfile(
      const PlayerProfile(wallet: Wallet(coins: 44)),
    );
    final calls = <String>[];
    final sync = ProfileSyncService.withSeams(
      storage: storage,
      currentUid: () => auth.uid,
      rpc: (function, params) async {
        calls.add(function);
        if (function == 'claim_profile') {
          return [
            {'profile_snapshot': null, 'snapshot_revision': 0},
          ];
        }
        expect(
          ((params['p_snapshot'] as Map)['profile'] as Map)['coins'],
          44,
        );
        return true;
      },
    );
    final controller = AccountFlowController(
      auth: auth,
      storage: storage,
      sync: sync,
      drainAccountWork: () async {},
      reloadLocalState: () async {},
    );

    expect(
      await controller.beginGoogle(hasDisplayName: true),
      GoogleFlowOutcome.linkedReady,
    );
    expect(calls, ['claim_profile', 'push_profile']);
    expect(storage.loadProfile().wallet.coins, 44);
  });

  test('adoption waits for old-account work before changing identity',
      () async {
    final releaseJob = Completer<void>();
    var adopted = false;
    late final _FakeAuthService auth;
    auth = _FakeAuthService(
      uid: 'guest-1',
      googleResult: GoogleAuthResult.collision,
      onAdopt: () {
        adopted = true;
        auth.uid = 'cloud-1';
      },
    );
    final storage = InMemoryStorageService(currentUserId: () => auth.uid);
    await storage.rebindOwner(auth.uid!);
    final sync = ProfileSyncService.withSeams(
      storage: storage,
      currentUid: () => auth.uid,
      rpc: (function, _) async {
        if (function == 'push_profile') return true;
        if (auth.uid == 'guest-1') {
          return [
            {'profile_snapshot': null, 'snapshot_revision': 0},
          ];
        }
        return [
          {'profile_snapshot': _snapshot(coins: 9), 'snapshot_revision': 1},
        ];
      },
    );
    final controller = AccountFlowController(
      auth: auth,
      storage: storage,
      sync: sync,
      drainAccountWork: () async {
        await releaseJob.future;
        // Once rebound, the guard cannot recognize this future's provenance;
        // finishing it before adoption is the actual safety mechanism.
        await storage.addCoins(3);
      },
      reloadLocalState: () async {},
    );
    expect(
      await controller.beginGoogle(hasDisplayName: true),
      GoogleFlowOutcome.collision,
    );

    final adoption = controller.confirmAdopt();
    await Future<void>.delayed(Duration.zero);
    expect(adopted, isFalse);
    expect(auth.uid, 'guest-1');
    releaseJob.complete();
    expect(await adoption, GoogleFlowOutcome.adoptedReady);
    expect(adopted, isTrue);
  });

  test('sign out and delete both rebind ownership to the fresh guest',
      () async {
    for (final delete in [false, true]) {
      final auth = _FakeAuthService(uid: 'cloud-1', googleIdentity: true);
      final storage = InMemoryStorageService(currentUserId: () => auth.uid);
      await storage.rebindOwner(auth.uid!);
      await storage.saveProfile(
        const PlayerProfile(wallet: Wallet(coins: 50)),
      );
      final sync = ProfileSyncService.withSeams(
        storage: storage,
        currentUid: () => auth.uid,
        rpc: (_, __) async => true,
      )..arm();
      final controller = AccountFlowController(
        auth: auth,
        storage: storage,
        sync: sync,
        drainAccountWork: () async {},
        reloadLocalState: () async {},
      );

      if (delete) {
        await controller.deleteAccount();
      } else {
        await controller.signOut();
      }
      expect(auth.uid, 'guest-2');
      expect(storage.owner!.uid, 'guest-2');
      expect(storage.loadProfile(), PlayerProfile.empty);
      await storage.addCoins(1);
    }
  });

  test('native sign-out failure cannot skip anonymous rebind after Supabase',
      () async {
    final errors = <Object>[];
    final auth = _FakeAuthService(
      uid: 'cloud-1',
      googleIdentity: true,
      signOutErrorAfterSessionEnds: StateError('native sign-out failed'),
    );
    final storage = InMemoryStorageService(currentUserId: () => auth.uid);
    await storage.rebindOwner('cloud-1');
    final sync = ProfileSyncService.withSeams(
      storage: storage,
      currentUid: () => auth.uid,
      rpc: (_, __) async => true,
    )..arm();
    final controller = AccountFlowController(
      auth: auth,
      storage: storage,
      sync: sync,
      drainAccountWork: () async {},
      reloadLocalState: () async {},
      onError: (error, _) => errors.add(error),
    );

    await controller.signOut();

    expect(auth.uid, 'guest-2');
    expect(storage.owner!.uid, 'guest-2');
    expect(errors, hasLength(1));
  });
}

class _SequenceRandom implements Random {
  final Iterator<int> _values;

  _SequenceRandom(List<int> values) : _values = values.iterator;

  @override
  bool nextBool() => nextInt(2) == 1;

  @override
  double nextDouble() => nextInt(1000000) / 1000000;

  @override
  int nextInt(int max) {
    _values.moveNext();
    return _values.current % max;
  }
}

Map<String, dynamic> _snapshot({required int coins}) => {
      'schema_version': 1,
      'profile': PlayerProfile(wallet: Wallet(coins: coins)).toJson(),
      'stats': {
        for (final difficulty in Difficulty.values)
          difficulty.name: LifetimeStats.empty.toJson(),
      },
      'history': <dynamic>[],
    };

class _FakeAuthService implements AuthService {
  String? uid;
  int takenNames;
  final GoogleAuthResult googleResult;
  final VoidCallback? onAdopt;
  final List<String> names = [];
  bool googleIdentity;
  final Object? signOutErrorAfterSessionEnds;

  _FakeAuthService({
    required this.uid,
    this.takenNames = 0,
    this.googleResult = GoogleAuthResult.linked,
    this.onAdopt,
    this.googleIdentity = false,
    this.signOutErrorAfterSessionEnds,
  });

  @override
  String? get currentUserId => uid;

  @override
  bool get hasGoogleIdentity => googleIdentity;

  @override
  bool get isSignedIn => uid != null;

  @override
  Future<GoogleAuthResult> signInWithGoogle() async => googleResult;

  @override
  Future<GoogleAuthResult> confirmAdopt() async {
    onAdopt?.call();
    googleIdentity = true;
    return GoogleAuthResult.adopted;
  }

  @override
  void cancelGoogleAdoption() {}

  @override
  Future<void> setDisplayName(String name, {String? avatar}) async {
    names.add(name);
    if (takenNames > 0) {
      takenNames--;
      throw DisplayNameTakenException();
    }
  }

  @override
  Future<void> signOut() async {
    uid = null;
    googleIdentity = false;
    final error = signOutErrorAfterSessionEnds;
    if (error != null) throw error;
  }

  @override
  Future<void> deleteAccount() async {
    uid = null;
    googleIdentity = false;
  }

  @override
  Future<void> ensureSignedIn() async => uid = 'guest-2';

  @override
  Future<String?> displayName() async => names.lastOrNull;

  @override
  Future<bool> hasDisplayName() async => names.isNotEmpty;

  @override
  Future<({String? name, String? avatar})> profile() async =>
      (name: names.lastOrNull, avatar: null);
}
