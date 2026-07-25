import 'dart:math';

import '../domain/constants.dart';
import '../domain/models/day_result.dart';
import '../domain/models/difficulty.dart';

import 'storage/game_snapshot.dart';
import 'storage/lifetime_stats.dart';
import 'storage/player_profile.dart';

export 'storage/activity_streak.dart';
export 'storage/cosmetics_inventory.dart';
export 'storage/game_snapshot.dart';
export 'storage/lifetime_stats.dart';
export 'storage/player_profile.dart';
export 'storage/player_settings.dart';
export 'storage/prize_ledger.dart';
export 'storage/progression.dart';
export 'storage/rivalry.dart';
export 'storage/wallet.dart';

/// Cap on streak-freeze tokens a single tier can bank (prevents infinite
/// shielding). One token bridges exactly one missed UTC day.
const int kMaxStreakFreezeTokens = 3;

/// Install-scoped ownership commit for the account-scoped Hive keys.
///
/// [restoreComplete] is written false before any live restore key and true only
/// after promotion; [recoveryRequired] survives relaunches after validation
/// failure and may be cleared only by a committed restore or explicit rebind.
/// The record deliberately contains no provider metadata: bootstrap branches
/// on the authenticated identity, while this value answers only which uid owns
/// the bytes currently visible to storage writes.
class LocalOwner {
  final String uid;
  final int snapshotRevision;
  final bool restoreComplete;
  final bool recoveryRequired;

  /// True once this install has actually won `claim_profile` for [uid].
  ///
  /// Binding an owner locally is NOT the same as holding the server-side claim:
  /// an install that upgraded from a pre-snapshot build already has a
  /// display_name, so it never passes through the auth gate and never claimed.
  /// Pushing while `players.active_device_id` is still null matches zero rows
  /// and reports "superseded" on a device nothing has superseded. Syncing
  /// therefore arms on this flag, never on a bare uid match. Defaults to false
  /// so owner records written by older builds re-claim instead of trusting it.
  final bool claimed;

  const LocalOwner({
    required this.uid,
    required this.snapshotRevision,
    required this.restoreComplete,
    required this.recoveryRequired,
    this.claimed = false,
  });

  LocalOwner copyWith({
    int? snapshotRevision,
    bool? restoreComplete,
    bool? recoveryRequired,
    bool? claimed,
  }) =>
      LocalOwner(
        uid: uid,
        snapshotRevision: snapshotRevision ?? this.snapshotRevision,
        restoreComplete: restoreComplete ?? this.restoreComplete,
        recoveryRequired: recoveryRequired ?? this.recoveryRequired,
        claimed: claimed ?? this.claimed,
      );

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'snapshot_revision': snapshotRevision,
        'restore_complete': restoreComplete,
        'recovery_required': recoveryRequired,
        'claimed': claimed,
      };

  static LocalOwner fromJson(Map<String, dynamic> json) => LocalOwner(
        uid: json['uid'] as String,
        snapshotRevision: json['snapshot_revision'] as int,
        restoreComplete: json['restore_complete'] as bool,
        recoveryRequired: json['recovery_required'] as bool,
        claimed: (json['claimed'] as bool?) ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is LocalOwner &&
      other.uid == uid &&
      other.snapshotRevision == snapshotRevision &&
      other.restoreComplete == restoreComplete &&
      other.recoveryRequired == recoveryRequired &&
      other.claimed == claimed;

  @override
  int get hashCode =>
      Object.hash(uid, snapshotRevision, restoreComplete, recoveryRequired,
          claimed);
}

enum StorageWriteBlockReason {
  ownerMismatch,
  restoreIncomplete,
  recoveryRequired,
}

class StorageWriteBlockedException implements Exception {
  final StorageWriteBlockReason reason;

  const StorageWriteBlockedException(this.reason);

  @override
  String toString() => 'StorageWriteBlockedException(${reason.name})';
}

typedef StorageChangeListener = void Function();

/// Generates the install claim id as an RFC 4122 version-4 UUID without adding
/// another dependency. It survives account-only wipes so a successful claim
/// remains valid until another physical install claims the cloud row.
String generateDeviceId([Random? random]) {
  final source = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => source.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

/// Local persistence boundary. Snapshots and stats are keyed by
/// `(date, difficulty)` / `difficulty`. The Hive implementation lives in
/// hive_storage_service.dart; this in-memory fake is used by tests.
abstract class StorageService {
  Future<void> init();

  /// Install-scoped claim/ownership state. Payload writes advance
  /// [localRevision] in the same atomic batch; a successful push copies only
  /// its captured revision to [syncedRevision], so a concurrent local write
  /// remains dirty instead of being silently acknowledged.
  String get deviceId;
  LocalOwner? get owner;
  bool get ownerRecordCorrupt;
  int get localRevision;
  int get syncedRevision;
  bool get isDirty;
  int captureRevision();
  Future<bool> markPushed(int capturedRevision);
  Future<void> discardStaleDirty();
  Future<void> recordClaim(String uid, {required int snapshotRevision});
  Future<void> rebindOwner(String uid,
      {int snapshotRevision = 0, bool claimed = false});
  Future<void> markRecoveryRequired(String uid,
      {required int snapshotRevision});
  Future<void> startRestore(String uid, {required int snapshotRevision});
  Future<void> finishRestore(String uid, {required int snapshotRevision});
  Future<void> stageRestore({
    required PlayerProfile profile,
    required Map<Difficulty, LifetimeStats> stats,
    required List<DayResult> history,
  });
  Future<void> promoteStagedRestore();
  void addChangeListener(StorageChangeListener listener);
  void removeChangeListener(StorageChangeListener listener);
  GameSnapshot? loadSnapshot(String date, Difficulty difficulty);
  Future<void> saveSnapshot(GameSnapshot snapshot); // carries date + difficulty
  LifetimeStats loadStats(Difficulty difficulty);
  Future<void> saveStats(Difficulty difficulty, LifetimeStats stats);

  /// Cross-tier profile (headline streak, achievements, cosmetics, notif prefs).
  PlayerProfile loadProfile();
  Future<void> saveProfile(PlayerProfile profile);

  /// The SINGLE awaited path for a pure coin credit/refund: loads the profile,
  /// writes `coins = max(0, coins + delta)` (clamped at 0), awaits the save, and
  /// returns the new balance. [delta] is signed (positive credit, negative
  /// refund). Atomic compound writes (loot claim, cosmetic purchase) stay
  /// combined elsewhere — this is only for standalone coin movement.
  Future<int> addCoins(int delta);

  /// Append-only day-result history (Phase 4), powering the stats calendar.
  /// [loadHistory] returns the persisted results in insertion (chronological)
  /// order, oldest first; an empty list when nothing has been recorded (so it
  /// loads cleanly for pre-Phase-4 players). [appendResult] adds one result and
  /// caps the log to [kHistoryRetentionDays] entries, dropping the oldest.
  List<DayResult> loadHistory();
  Future<void> appendResult(DayResult result);
  Future<void> replaceHistory(List<DayResult> history);
  Future<void> wipeAccountData();

  /// Factory-reset every key, including install identity. Account switching
  /// must use [wipeAccountData], because deleting device_id after a claim would
  /// invalidate that claim before the first push.
  Future<void> wipeAll();
}

class InMemoryStorageService implements StorageService {
  final String? Function() _currentUserId;
  final void Function()? _onChanged;
  final Set<StorageChangeListener> _listeners = {};
  String _deviceId;
  final Map<String, GameSnapshot> _snapshots = {};
  final Map<String, LifetimeStats> _stats = {};
  PlayerProfile _profile = PlayerProfile.empty;
  final List<DayResult> _history = [];
  LocalOwner? _owner;
  int _localRevision = 0;
  int _syncedRevision = 0;
  PlayerProfile? _stagedProfile;
  Map<Difficulty, LifetimeStats>? _stagedStats;
  List<DayResult>? _stagedHistory;

  InMemoryStorageService({
    String? Function()? currentUserId,
    void Function()? onChanged,
  })  : _currentUserId = currentUserId ?? (() => null),
        _onChanged = onChanged,
        _deviceId = generateDeviceId();

  @override
  String get deviceId => _deviceId;

  @override
  int get localRevision => _localRevision;

  @override
  int get syncedRevision => _syncedRevision;

  @override
  bool get isDirty => _localRevision != _syncedRevision;

  @override
  int captureRevision() => _localRevision;

  @override
  Future<bool> markPushed(int capturedRevision) async {
    _syncedRevision = capturedRevision;
    final owner = _owner;
    if (owner != null) {
      _owner = owner.copyWith(snapshotRevision: owner.snapshotRevision + 1);
    }
    return _localRevision == capturedRevision;
  }

  @override
  Future<void> discardStaleDirty() async {
    _syncedRevision = _localRevision;
  }

  @override
  Future<void> recordClaim(String uid, {required int snapshotRevision}) async {
    final existing = _owner;
    _owner = LocalOwner(
      uid: uid,
      snapshotRevision: snapshotRevision,
      restoreComplete: existing?.restoreComplete ?? true,
      recoveryRequired: existing?.recoveryRequired ?? false,
      claimed: true,
    );
  }

  @override
  LocalOwner? get owner => _owner;

  @override
  bool get ownerRecordCorrupt => false;

  void _guardWrite() {
    final owner = _owner;
    if (owner == null) return;
    if (!owner.restoreComplete) {
      throw const StorageWriteBlockedException(
          StorageWriteBlockReason.restoreIncomplete);
    }
    if (owner.recoveryRequired) {
      throw const StorageWriteBlockedException(
          StorageWriteBlockReason.recoveryRequired);
    }
    final currentUserId = _currentUserId();
    if (currentUserId != null && currentUserId != owner.uid) {
      throw const StorageWriteBlockedException(
          StorageWriteBlockReason.ownerMismatch);
    }
  }

  @override
  Future<void> rebindOwner(String uid,
      {int snapshotRevision = 0, bool claimed = false}) async {
    _owner = LocalOwner(
      uid: uid,
      snapshotRevision: snapshotRevision,
      restoreComplete: true,
      recoveryRequired: false,
      claimed: claimed,
    );
    _syncedRevision = _localRevision;
  }

  @override
  Future<void> markRecoveryRequired(String uid,
      {required int snapshotRevision}) async {
    _owner = LocalOwner(
      uid: uid,
      snapshotRevision: snapshotRevision,
      restoreComplete: _owner?.restoreComplete ?? true,
      recoveryRequired: true,
      claimed: _owner?.claimed ?? false,
    );
  }

  @override
  Future<void> startRestore(String uid, {required int snapshotRevision}) async {
    _owner = LocalOwner(
      uid: uid,
      snapshotRevision: snapshotRevision,
      restoreComplete: false,
      recoveryRequired: _owner?.recoveryRequired ?? false,
      claimed: true,
    );
  }

  @override
  Future<void> finishRestore(String uid,
      {required int snapshotRevision}) async {
    await rebindOwner(uid, snapshotRevision: snapshotRevision, claimed: true);
  }

  static String _snapKey(String date, Difficulty difficulty) =>
      '$date:${difficulty.name}';

  @override
  Future<void> init() async {}

  @override
  GameSnapshot? loadSnapshot(String date, Difficulty difficulty) =>
      _snapshots[_snapKey(date, difficulty)];

  @override
  Future<void> saveSnapshot(GameSnapshot snapshot) async {
    _guardWrite();
    _snapshots[_snapKey(snapshot.date, snapshot.difficulty)] = snapshot;
  }

  @override
  LifetimeStats loadStats(Difficulty difficulty) =>
      _stats[difficulty.name] ?? LifetimeStats.empty;

  @override
  Future<void> saveStats(Difficulty difficulty, LifetimeStats stats) async {
    _guardWrite();
    _stats[difficulty.name] = stats;
    _markDirty();
  }

  @override
  PlayerProfile loadProfile() => _profile;

  @override
  Future<void> saveProfile(PlayerProfile profile) async {
    _guardWrite();
    _profile = profile;
    _markDirty();
  }

  @override
  Future<int> addCoins(int delta) async {
    final updated = _profile.creditCoins(delta);
    await saveProfile(updated);
    return updated.wallet.coins;
  }

  @override
  List<DayResult> loadHistory() => List<DayResult>.unmodifiable(_history);

  @override
  Future<void> appendResult(DayResult result) async {
    _guardWrite();
    _history.add(result);
    // Cap to the retention window, dropping the oldest entries.
    while (_history.length > kHistoryRetentionDays) {
      _history.removeAt(0);
    }
    _markDirty();
  }

  @override
  Future<void> replaceHistory(List<DayResult> history) async {
    _guardWrite();
    _history
      ..clear()
      ..addAll(history.length <= kHistoryRetentionDays
          ? history
          : history.sublist(history.length - kHistoryRetentionDays));
    _markDirty();
  }

  @override
  void addChangeListener(StorageChangeListener listener) =>
      _listeners.add(listener);

  @override
  void removeChangeListener(StorageChangeListener listener) =>
      _listeners.remove(listener);

  @override
  Future<void> stageRestore({
    required PlayerProfile profile,
    required Map<Difficulty, LifetimeStats> stats,
    required List<DayResult> history,
  }) async {
    _stagedProfile = profile;
    _stagedStats = Map.of(stats);
    _stagedHistory = List.of(history);
  }

  @override
  Future<void> promoteStagedRestore() async {
    final profile = _stagedProfile;
    final stats = _stagedStats;
    final history = _stagedHistory;
    if (profile == null || stats == null || history == null) {
      throw StateError('No staged restore');
    }
    _profile = profile;
    _stats
      ..clear()
      ..addEntries(stats.entries.map((e) => MapEntry(e.key.name, e.value)));
    _history
      ..clear()
      ..addAll(history);
    _stagedProfile = null;
    _stagedStats = null;
    _stagedHistory = null;
  }

  @override
  Future<void> wipeAccountData() async {
    _snapshots.clear();
    _stats.clear();
    _profile = PlayerProfile.empty;
    _history.clear();
    _stagedProfile = null;
    _stagedStats = null;
    _stagedHistory = null;
  }

  @override
  Future<void> wipeAll() async {
    _snapshots.clear();
    _stats.clear();
    _profile = PlayerProfile.empty;
    _history.clear();
    _owner = null;
    _localRevision = 0;
    _syncedRevision = 0;
    _deviceId = generateDeviceId();
  }

  void _markDirty() {
    _localRevision++;
    _onChanged?.call();
    for (final listener in List<StorageChangeListener>.of(_listeners)) {
      listener();
    }
  }
}
