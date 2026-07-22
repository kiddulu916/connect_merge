import 'dart:async';
import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/models/day_result.dart';
import '../domain/models/difficulty.dart';
import 'storage_service.dart';

const int kProfileSchemaVersion = 1;
const int kMaxProfileSnapshotBytes = 262144;

enum SnapshotOutcome {
  restored,
  missingPlayerRow,
  emptySnapshot,
  corrupt,
  oversized,
  newerVersion,
  superseded,
  pushFailed,
}

enum BootstrapOutcome {
  ready,
  offlineReady,
  needsAuthGate,
  restored,
  emptySnapshot,
  missingPlayerRow,
  blockedRecovery,
  blockedInterruptedRestore,
}

enum ProfilePushOutcome { clean, pushed, failed, superseded }

typedef ProfileRpc = Future<dynamic> Function(
  String function,
  Map<String, dynamic> params,
);

class _ValidatedSnapshot {
  final PlayerProfile profile;
  final Map<Difficulty, LifetimeStats> stats;
  final List<DayResult> history;

  const _ValidatedSnapshot({
    required this.profile,
    required this.stats,
    required this.history,
  });
}

class _ClaimedProfile {
  final Object? snapshot;
  final int revision;

  const _ClaimedProfile({required this.snapshot, required this.revision});
}

/// Owns the cloud snapshot claim/push protocol. Pulling is never sequenced
/// separately from the device claim: `claim_profile` closes that clobber
/// window with one database statement.
class ProfileSyncService {
  final StorageService storage;
  final String? Function() currentUid;
  final ProfileRpc _rpc;
  final Duration debounce;
  VoidCallback? onSuperseded;
  final void Function(Object error, StackTrace? stack, {bool fatal})? _onError;
  final void Function(String message)? _onLog;

  Timer? _debounceTimer;
  Future<ProfilePushOutcome>? _inFlight;
  bool _queued = false;
  bool _forceQueued = false;
  bool _armed = false;
  bool _superseded = false;
  bool _pausing = false;
  bool _forcePushPending = false;

  ProfileSyncService({
    required SupabaseClient client,
    required this.storage,
    required this.currentUid,
    this.debounce = const Duration(seconds: 5),
    this.onSuperseded,
    void Function(Object error, StackTrace? stack, {bool fatal})? onError,
    void Function(String message)? onLog,
  })  : _rpc = ((function, params) => client.rpc(function, params: params)),
        _onError = onError,
        _onLog = onLog;

  ProfileSyncService.withSeams({
    required this.storage,
    required this.currentUid,
    required ProfileRpc rpc,
    this.debounce = const Duration(seconds: 5),
    this.onSuperseded,
    void Function(Object error, StackTrace? stack, {bool fatal})? onError,
    void Function(String message)? onLog,
  })  : _rpc = rpc,
        _onError = onError,
        _onLog = onLog;

  bool get isArmed => _armed;
  bool get isSuperseded => _superseded;

  static Map<String, dynamic> collect(StorageService storage) => {
        'schema_version': kProfileSchemaVersion,
        'profile': storage.loadProfile().toJson(),
        'stats': {
          for (final difficulty in Difficulty.values)
            difficulty.name: storage.loadStats(difficulty).toJson(),
        },
        'history':
            storage.loadHistory().map((result) => result.toJson()).toList(),
      };

  /// Runs the authoritative bootstrap table. It never claims on a normal
  /// matching launch, so two already-open devices cannot ping-pong ownership.
  Future<BootstrapOutcome> bootstrap({required bool hasGoogleIdentity}) async {
    if (storage.ownerRecordCorrupt) {
      _onLog?.call('profile bootstrap blocked: corrupt owner record');
      return BootstrapOutcome.blockedRecovery;
    }
    final localOwner = storage.owner;
    final uid = currentUid();
    if (localOwner?.recoveryRequired ?? false) {
      _onLog?.call('profile bootstrap blocked: recovery required');
      return BootstrapOutcome.blockedRecovery;
    }
    if (localOwner != null && !localOwner.restoreComplete) {
      _onLog?.call('profile bootstrap: interrupted restore');
      if (uid == null) return BootstrapOutcome.blockedInterruptedRestore;
      if (hasGoogleIdentity) return _bootstrapRestore();
      if (localOwner.uid != uid) {
        _onLog?.call('profile bootstrap: anonymous owner mismatch');
        await storage.wipeAccountData();
        await storage.rebindOwner(uid);
        return BootstrapOutcome.needsAuthGate;
      }
      return _bootstrapRestore();
    }
    if (uid == null) return BootstrapOutcome.offlineReady;
    // An owner that has never won `claim_profile` cannot push: the guarded
    // UPDATE matches zero rows and would report "superseded" on a device
    // nothing superseded. This is the normal state for installs that upgraded
    // from a pre-snapshot build (they already have a display_name, so they
    // never pass through the auth gate) and for any bind whose claim failed
    // offline. Both must claim here rather than silently never syncing.
    if (localOwner == null || (localOwner.uid == uid && !localOwner.claimed)) {
      return _bootstrapClaimLocal(uid);
    }
    if (localOwner.uid == uid) {
      arm();
      return BootstrapOutcome.ready;
    }
    if (hasGoogleIdentity) {
      _onLog?.call('profile bootstrap: Google owner mismatch');
      return _bootstrapRestore();
    }

    // An anonymous mismatch is the delete/sign-out crash branch: its local
    // bytes belong to the already-gone identity, so wipe then bind the guest.
    _onLog?.call('profile bootstrap: anonymous owner mismatch');
    await storage.wipeAccountData();
    await storage.rebindOwner(uid);
    return BootstrapOutcome.needsAuthGate;
  }

  /// Claim for a uid whose local bytes already belong to it. Never the
  /// destructive adoption path: nothing here is another account's data, so a
  /// null cloud snapshot just means this player has not synced yet.
  ///
  /// A claim failure (offline, transient) must not strand the install as a
  /// permanently-unclaimed owner, so the owner is bound unclaimed and the next
  /// bootstrap retries. Sync stays disarmed until a claim actually lands.
  Future<BootstrapOutcome> _bootstrapClaimLocal(String uid) async {
    try {
      final outcome = await claimAndPushLocal();
      if (outcome == SnapshotOutcome.missingPlayerRow) {
        // No `players` row yet — the normal pre-display-name state, not a
        // failure. Name creation writes the row, then claims.
        if (storage.owner == null) await storage.rebindOwner(uid);
        return BootstrapOutcome.missingPlayerRow;
      }
      return BootstrapOutcome.ready;
    } catch (error, stack) {
      _onError?.call(error, stack);
      _onLog?.call('profile bootstrap claim failed; will retry next launch');
      if (storage.owner == null) await storage.rebindOwner(uid);
      return BootstrapOutcome.offlineReady;
    }
  }

  Future<BootstrapOutcome> _bootstrapRestore() async {
    final outcome = await claimAndRestore();
    return switch (outcome) {
      SnapshotOutcome.restored => BootstrapOutcome.restored,
      SnapshotOutcome.emptySnapshot => BootstrapOutcome.emptySnapshot,
      SnapshotOutcome.missingPlayerRow => BootstrapOutcome.missingPlayerRow,
      _ => BootstrapOutcome.blockedRecovery,
    };
  }

  Future<SnapshotOutcome> claimAndRestore() async {
    _disarm();
    _superseded = false;
    _forcePushPending = false;
    final claim = await _claim();
    if (claim == null) return SnapshotOutcome.missingPlayerRow;
    final uid = currentUid()!;
    if (claim.snapshot == null) {
      await storage.wipeAccountData();
      // The claim above succeeded, so this owner genuinely holds it; binding
      // unclaimed here would leave the account permanently unable to push.
      await storage.rebindOwner(
        uid,
        snapshotRevision: claim.revision,
        claimed: true,
      );
      arm();
      _onLog?.call('profile restore outcome: empty cloud');
      return SnapshotOutcome.emptySnapshot;
    }
    if (claim.snapshot is! Map) {
      await storage.markRecoveryRequired(
        uid,
        snapshotRevision: claim.revision,
      );
      _onLog?.call('profile restore outcome: corrupt');
      return SnapshotOutcome.corrupt;
    }
    final outcome = await restore(
      Map<String, dynamic>.from(claim.snapshot! as Map),
      serverRevision: claim.revision,
    );
    if (outcome == SnapshotOutcome.restored) arm();
    return outcome;
  }

  /// Used when Google was linked into the current uid. Local bytes still
  /// belong to that uid, so claiming must be followed by an initial push, not
  /// the destructive empty-cloud adoption path.
  Future<SnapshotOutcome> claimAndPushLocal() async {
    _disarm();
    _superseded = false;
    final claim = await _claim();
    if (claim == null) return SnapshotOutcome.missingPlayerRow;
    await storage.recordClaim(
      currentUid()!,
      snapshotRevision: claim.revision,
    );
    arm();
    // This flag is separate from dirty revisions: an existing install can be
    // locally clean yet still need its first post-link cloud snapshot. A
    // network failure must leave that obligation retryable by flush/pause.
    _forcePushPending = true;
    final pushed = await pushNow(force: true);
    return switch (pushed) {
      ProfilePushOutcome.pushed ||
      ProfilePushOutcome.clean =>
        SnapshotOutcome.restored,
      ProfilePushOutcome.superseded => SnapshotOutcome.superseded,
      ProfilePushOutcome.failed => SnapshotOutcome.pushFailed,
    };
  }

  Future<_ClaimedProfile?> _claim() async {
    final uid = currentUid();
    if (uid == null) throw StateError('Cannot claim without a session.');
    try {
      final response = await _rpc('claim_profile', {
        'p_device': storage.deviceId,
      });
      final rows = response as List<dynamic>;
      if (rows.isEmpty) {
        _onLog?.call('profile claim outcome: missing player row');
        return null;
      }
      final row = Map<String, dynamic>.from(rows.single as Map);
      final rawSnapshot = row['profile_snapshot'];
      return _ClaimedProfile(
        snapshot: rawSnapshot,
        revision: (row['snapshot_revision'] as num).toInt(),
      );
    } catch (error, stack) {
      _onError?.call(error, stack);
      _onLog?.call('profile claim failed');
      rethrow;
    }
  }

  Future<SnapshotOutcome> restore(
    Map<String, dynamic> snapshot, {
    required int serverRevision,
  }) async {
    final uid = currentUid();
    if (uid == null) throw StateError('Cannot restore without a session.');
    final outcome = _validationOutcome(snapshot);
    if (outcome != null) {
      await storage.markRecoveryRequired(
        uid,
        snapshotRevision: serverRevision,
      );
      _disarm();
      _onLog?.call('profile restore outcome: ${outcome.name}');
      return outcome;
    }

    final validated = _validate(snapshot);
    // Incomplete is persisted before any live key, and complete after every
    // promotion. This remains safe during same-uid Reload profile crashes.
    await storage.startRestore(uid, snapshotRevision: serverRevision);
    await storage.stageRestore(
      profile: validated.profile,
      stats: validated.stats,
      history: validated.history,
    );
    await storage.promoteStagedRestore();
    await storage.finishRestore(uid, snapshotRevision: serverRevision);
    _onLog?.call('profile restore outcome: restored');
    return SnapshotOutcome.restored;
  }

  SnapshotOutcome? _validationOutcome(Map<String, dynamic> snapshot) {
    if (utf8.encode(jsonEncode(snapshot)).length > kMaxProfileSnapshotBytes) {
      return SnapshotOutcome.oversized;
    }
    final version = snapshot['schema_version'];
    if (version is int && version > kProfileSchemaVersion) {
      return SnapshotOutcome.newerVersion;
    }
    try {
      _validate(snapshot);
      return null;
    } catch (_) {
      return SnapshotOutcome.corrupt;
    }
  }

  _ValidatedSnapshot _validate(Map<String, dynamic> snapshot) {
    if (snapshot['schema_version'] != kProfileSchemaVersion) {
      throw const FormatException('Unsupported profile schema.');
    }
    final profile = PlayerProfile.fromJson(
      Map<String, dynamic>.from(snapshot['profile'] as Map),
    );
    final statsJson = Map<String, dynamic>.from(snapshot['stats'] as Map);
    if (statsJson.length != Difficulty.values.length ||
        !Difficulty.values
            .every((difficulty) => statsJson.containsKey(difficulty.name))) {
      throw const FormatException('Profile stats tiers are incomplete.');
    }
    final stats = {
      for (final difficulty in Difficulty.values)
        difficulty: LifetimeStats.fromJson(
          Map<String, dynamic>.from(statsJson[difficulty.name] as Map),
        ),
    };
    final history = (snapshot['history'] as List)
        .map((value) =>
            DayResult.fromJson(Map<String, dynamic>.from(value as Map)))
        .toList();
    return _ValidatedSnapshot(profile: profile, stats: stats, history: history);
  }

  void arm() {
    final uid = currentUid();
    final localOwner = storage.owner;
    if (_armed ||
        _superseded ||
        uid == null ||
        localOwner == null ||
        localOwner.uid != uid ||
        !localOwner.restoreComplete ||
        localOwner.recoveryRequired ||
        // Arming on a bare uid match would push against a null
        // active_device_id and report a bogus supersession.
        !localOwner.claimed) {
      return;
    }
    _armed = true;
    storage.addChangeListener(_schedulePush);
    // Dirty revisions survive process death. Re-arming on launch must resume
    // that obligation even when no new write occurs to trigger the listener.
    if (storage.isDirty || _forcePushPending) _schedulePush();
  }

  void _disarm() {
    if (_armed) storage.removeChangeListener(_schedulePush);
    _armed = false;
    _debounceTimer?.cancel();
    _debounceTimer = null;
  }

  void _schedulePush() {
    if (!_armed || _superseded || _pausing) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => unawaited(pushNow()));
  }

  Future<ProfilePushOutcome> pushNow({bool force = false}) {
    if (_superseded) return Future.value(ProfilePushOutcome.superseded);
    if (!_armed || _pausing) return Future.value(ProfilePushOutcome.clean);
    _queued = true;
    _forceQueued = _forceQueued || force;
    final running = _inFlight;
    if (running != null) return running;
    final future = _drainPushQueue();
    _inFlight = future;
    unawaited(future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    }));
    return future;
  }

  Future<ProfilePushOutcome> _drainPushQueue() async {
    var outcome = ProfilePushOutcome.clean;
    while (_queued && _armed && !_superseded && !_pausing) {
      _queued = false;
      final force = _forceQueued || _forcePushPending;
      _forceQueued = false;
      if (!storage.isDirty && !force) continue;
      outcome = await _pushOnce();
      if (outcome == ProfilePushOutcome.failed ||
          outcome == ProfilePushOutcome.superseded) {
        return outcome;
      }
    }
    return outcome;
  }

  Future<ProfilePushOutcome> _pushOnce() async {
    final uid = currentUid();
    if (uid == null) return ProfilePushOutcome.failed;
    final localOwner = storage.owner;
    if (localOwner == null ||
        localOwner.uid != uid ||
        !localOwner.restoreComplete ||
        localOwner.recoveryRequired ||
        !localOwner.claimed) {
      _onLog?.call('profile push blocked: local owner mismatch');
      _disarm();
      return ProfilePushOutcome.failed;
    }
    final revision = storage.captureRevision();
    try {
      final accepted = await _rpc('push_profile', {
            'p_device': storage.deviceId,
            'p_snapshot': collect(storage),
          }) ==
          true;
      if (!accepted) {
        _superseded = true;
        _disarm();
        _onLog?.call('profile push superseded');
        onSuperseded?.call();
        return ProfilePushOutcome.superseded;
      }
      await storage.markPushed(revision);
      _forcePushPending = false;
      return ProfilePushOutcome.pushed;
    } catch (error, stack) {
      _onError?.call(error, stack);
      _onLog?.call('profile push failed');
      return ProfilePushOutcome.failed;
    }
  }

  Future<ProfilePushOutcome> flush() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (_superseded) return ProfilePushOutcome.superseded;
    if (!_armed || (!storage.isDirty && !_forcePushPending)) {
      return ProfilePushOutcome.clean;
    }
    var outcome = ProfilePushOutcome.clean;
    while (_armed && !_superseded && (storage.isDirty || _forcePushPending)) {
      outcome = await pushNow(force: _forcePushPending);
      if (outcome == ProfilePushOutcome.failed ||
          outcome == ProfilePushOutcome.superseded) {
        break;
      }
    }
    return outcome;
  }

  /// Session swaps call this before changing auth. It cancels queued work,
  /// waits for the one request that may already be on the wire, and drops the
  /// old account's dirty/superseded session state before a rebind.
  Future<void> pauseAndDrain({bool discardQueuedWork = true}) async {
    _pausing = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _queued = false;
    _forceQueued = false;
    _disarm();
    final running = _inFlight;
    if (running != null) await running;
    if (discardQueuedWork) {
      await storage.discardStaleDirty();
      _forcePushPending = false;
    }
    _superseded = false;
    _pausing = false;
  }

  void dispose() {
    _disarm();
  }
}

typedef VoidCallback = void Function();
