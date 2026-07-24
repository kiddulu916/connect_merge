import 'dart:math';

import '../infrastructure/auth_service.dart';
import '../infrastructure/profile_sync_service.dart';
import '../infrastructure/storage_service.dart';

/// Retains fire-and-forget account jobs until the next identity boundary. A
/// future that is not retained cannot be proven finished before currentUid is
/// changed, which would let its eventual storage write pass the new owner's
/// guard with the wrong provenance.
class AccountWorkTracker {
  final List<Future<void>> _pending = [];

  void retainAll(Iterable<Future<void>> work) => _pending.addAll(work);

  Future<void> drain() async {
    final work = List<Future<void>>.of(_pending);
    _pending.clear();
    if (work.isNotEmpty) await Future.wait(work);
  }
}

enum GoogleFlowOutcome {
  linkedNeedsDisplayName,
  linkedReady,
  collision,
  adoptedNeedsDisplayName,
  adoptedReady,
  blockedRecovery,
}

enum InitialAccountRoute { ready, authGate, displayName, recovery }

/// Converts the persisted bootstrap result plus the current identity into the
/// only four roots the app may expose. In particular, a linked Google user who
/// crashed before choosing a name must resume name creation, never return to
/// the provider gate and risk selecting another account.
InitialAccountRoute initialAccountRoute({
  required BootstrapOutcome bootstrap,
  required bool needsDisplayName,
  required bool hasGoogleIdentity,
}) {
  if (bootstrap == BootstrapOutcome.blockedRecovery ||
      bootstrap == BootstrapOutcome.blockedInterruptedRestore) {
    return InitialAccountRoute.recovery;
  }
  // Drop straight into name creation ONLY when the player has already
  // committed to Google but has no name yet (just linked, or crashed right
  // after linking). A fresh guest also has no players row — bootstrap reports
  // missingPlayerRow for both — so routing missingPlayerRow here would skip the
  // provider gate on every first run and never let anyone choose "Play as
  // guest" vs "Continue with Google". The gate is the entry point; only a
  // committed Google identity bypasses it.
  if (needsDisplayName && hasGoogleIdentity) {
    return InitialAccountRoute.displayName;
  }
  if (bootstrap == BootstrapOutcome.needsAuthGate ||
      bootstrap == BootstrapOutcome.missingPlayerRow ||
      needsDisplayName) {
    return InitialAccountRoute.authGate;
  }
  return InitialAccountRoute.ready;
}

/// Serializes every identity-changing operation around local ownership. Both
/// the first-run gate and ProfileScreen call this same controller, so a future
/// change cannot accidentally give those entry points different collision or
/// claim behavior.
class AccountFlowController {
  final AuthService auth;
  final ProfileSyncService sync;
  final StorageService storage;
  final Future<void> Function() drainAccountWork;
  final Future<void> Function() reloadLocalState;
  final Random _random;
  final void Function(String event)? _onEvent;
  final void Function(Object error, StackTrace? stack)? _onError;

  AccountFlowController({
    required this.auth,
    required this.sync,
    required this.storage,
    required this.drainAccountWork,
    required this.reloadLocalState,
    Random? random,
    void Function(String event)? onEvent,
    void Function(Object error, StackTrace? stack)? onError,
  })  : _random = random ?? Random.secure(),
        _onEvent = onEvent,
        _onError = onError;

  Future<GoogleFlowOutcome> beginGoogle({
    required bool hasDisplayName,
  }) async {
    try {
      if (hasDisplayName) {
        // Linking and claiming cannot be atomic across Google and Supabase.
        // Preflight the same anonymous uid so process death immediately after
        // link success still leaves a restorable cloud snapshot.
        await sync.pauseAndDrain(discardQueuedWork: false);
        final preflight = await sync.claimAndPushLocal();
        if (preflight != SnapshotOutcome.restored) {
          throw StateError('The pre-link profile push did not complete.');
        }
      }
      final result = await auth.signInWithGoogle();
      if (result == GoogleAuthResult.collision) {
        _onEvent?.call('google_collision');
        return GoogleFlowOutcome.collision;
      }
      _onEvent?.call('google_linked');
      if (!hasDisplayName) {
        return GoogleFlowOutcome.linkedNeedsDisplayName;
      }
      return GoogleFlowOutcome.linkedReady;
    } catch (error, stack) {
      _onEvent?.call('google_failed');
      _onError?.call(error, stack);
      rethrow;
    }
  }

  /// The server row is created by setDisplayName before this runs. Claiming
  /// afterwards distinguishes that legitimate new row from a missing row and
  /// makes the initial local snapshot the first cloud revision.
  Future<void> completeDisplayName() async {
    try {
      final owner = storage.owner;
      final uid = auth.currentUserId;
      // A Google adoption whose account had no players row deliberately keeps
      // the abandoned guest bytes blocked (owner mismatch) until name creation
      // creates that row. The retried claim then yields a validated empty/cloud
      // pull before any local account key is cleared.
      if (auth.hasGoogleIdentity &&
          uid != null &&
          owner != null &&
          owner.uid != uid) {
        final restored = await sync.claimAndRestore();
        if (restored != SnapshotOutcome.restored &&
            restored != SnapshotOutcome.emptySnapshot) {
          throw StateError('Could not restore the newly named profile.');
        }
        await reloadLocalState();
        return;
      }
      final outcome = await sync.claimAndPushLocal();
      if (outcome != SnapshotOutcome.restored) {
        throw StateError('Could not claim the newly named profile.');
      }
      await reloadLocalState();
    } catch (error, stack) {
      _onError?.call(error, stack);
      rethrow;
    }
  }

  Future<void> playAsGuest() async {
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 0; attempt < 3; attempt++) {
      final suffix = _random.nextInt(1000000).toString().padLeft(6, '0');
      try {
        await auth.setDisplayName('Player$suffix');
        await completeDisplayName();
        _onEvent?.call('guest_created');
        return;
      } on DisplayNameTakenException catch (error, stack) {
        lastError = error;
        lastStack = stack;
      } catch (error, stack) {
        _onEvent?.call('guest_creation_failed');
        _onError?.call(error, stack);
        rethrow;
      }
    }
    final error = lastError ?? StateError('Guest-name retries exhausted.');
    _onEvent?.call('guest_name_retry_exhausted');
    _onError?.call(error, lastStack);
    Error.throwWithStackTrace(error, lastStack ?? StackTrace.current);
  }

  Future<GoogleFlowOutcome> confirmAdopt() async {
    try {
      // Prize jobs can write after an await and therefore must finish while
      // both currentUid and owner still identify the guest. The storage guard
      // cannot infer the provenance of a future after the session changes.
      await drainAccountWork();
      await sync.pauseAndDrain();
      await auth.confirmAdopt();
      final outcome = await sync.claimAndRestore();
      if (outcome == SnapshotOutcome.missingPlayerRow) {
        _onEvent?.call('google_adopt_missing_profile');
        return GoogleFlowOutcome.adoptedNeedsDisplayName;
      }
      if (outcome != SnapshotOutcome.restored &&
          outcome != SnapshotOutcome.emptySnapshot) {
        _onEvent?.call('google_adopt_blocked');
        return GoogleFlowOutcome.blockedRecovery;
      }
      await reloadLocalState();
      _onEvent?.call('google_adopted');
      return GoogleFlowOutcome.adoptedReady;
    } catch (error, stack) {
      _onError?.call(error, stack);
      rethrow;
    }
  }

  void cancelAdopt() {
    auth.cancelGoogleAdoption();
    _onEvent?.call('google_adoption_cancelled');
  }

  Future<bool> canExitWithoutDataLoss() async {
    final result = await sync.flush();
    return result == ProfilePushOutcome.clean ||
        result == ProfilePushOutcome.pushed;
  }

  Future<void> signOut() async {
    await drainAccountWork();
    await sync.pauseAndDrain();
    await _finishAccountExit(auth.signOut, event: 'account_signed_out');
  }

  Future<void> deleteAccount() async {
    await drainAccountWork();
    await sync.pauseAndDrain();
    await _finishAccountExit(auth.deleteAccount, event: 'account_deleted');
  }

  /// Retry target when the old Supabase session is already gone but creating
  /// its replacement anonymous identity failed (usually transient network).
  Future<void> recoverFreshGuest() => _startFreshGuest();

  Future<void> reloadProfile() async {
    final outcome = await sync.claimAndRestore();
    if (outcome != SnapshotOutcome.restored &&
        outcome != SnapshotOutcome.emptySnapshot) {
      throw StateError('Cloud profile could not be restored.');
    }
    await reloadLocalState();
  }

  Future<void> _startFreshGuest() async {
    await storage.wipeAccountData();
    // This await is the account boundary: the gate is not exposed until the
    // replacement anonymous uid is known and committed as the local owner.
    await auth.ensureSignedIn();
    final uid = auth.currentUserId;
    if (uid == null) throw StateError('Anonymous sign-in returned no user.');
    await storage.rebindOwner(uid);
    await reloadLocalState();
  }

  Future<void> _finishAccountExit(
    Future<void> Function() endSession, {
    required String event,
  }) async {
    try {
      await endSession();
    } catch (error, stack) {
      // AuthService attempts Supabase and Google independently. If Supabase
      // already ended the session, local wipe/rebind must still complete; the
      // provider failure is telemetry, not permission to strand old bytes.
      if (auth.currentUserId != null) rethrow;
      _onError?.call(error, stack);
    }
    await _startFreshGuest();
    _onEvent?.call(event);
  }
}
