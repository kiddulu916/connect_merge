import 'dart:convert';

import 'package:hive/hive.dart';

import '../domain/constants.dart';
import '../domain/models/day_result.dart';
import '../domain/models/difficulty.dart';
import 'storage_service.dart';

/// Hive-backed persistence. Values are JSON strings, avoiding generated
/// TypeAdapters while keeping profile restore payloads inspectable.
class HiveStorageService implements StorageService {
  static const _boxName = 'connect_merge';
  static const _profileKey = 'profile';
  static const _historyKey = 'history';
  static const _ownerKey = 'owner';
  static const _deviceIdKey = 'device_id';
  static const _localRevisionKey = 'local_revision';
  static const _syncedRevisionKey = 'synced_revision';
  static const _stageProfileKey = '_restore:profile';
  static const _stageStatsKey = '_restore:stats';
  static const _stageHistoryKey = '_restore:history';

  static const _installKeys = {
    _ownerKey,
    _deviceIdKey,
    _localRevisionKey,
    _syncedRevisionKey,
  };

  final String? Function() _currentUserId;
  final void Function()? _onChanged;
  final Set<StorageChangeListener> _listeners = {};

  late Box<String> _box;

  HiveStorageService({
    String? Function()? currentUserId,
    void Function()? onChanged,
  })  : _currentUserId = currentUserId ?? (() => null),
        _onChanged = onChanged;

  static String _snapshotKey(String date, Difficulty difficulty) =>
      '$date:${difficulty.name}';

  static String _statsKey(Difficulty difficulty) => 'stats:${difficulty.name}';

  @override
  Future<void> init() async {
    _box = await Hive.openBox<String>(_boxName);
    if (_box.get(_deviceIdKey) == null) {
      await _box.putAll({
        _deviceIdKey: generateDeviceId(),
        _localRevisionKey: '0',
        _syncedRevisionKey: '0',
      });
    }
  }

  @override
  String get deviceId => _box.get(_deviceIdKey)!;

  @override
  LocalOwner? get owner {
    final raw = _box.get(_ownerKey);
    if (raw == null) return null;
    try {
      return LocalOwner.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  bool get ownerRecordCorrupt {
    final raw = _box.get(_ownerKey);
    if (raw == null) return false;
    try {
      LocalOwner.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
      return false;
    } catch (_) {
      return true;
    }
  }

  int _readRevision(String key) => int.tryParse(_box.get(key) ?? '0') ?? 0;

  @override
  int get localRevision => _readRevision(_localRevisionKey);

  @override
  int get syncedRevision => _readRevision(_syncedRevisionKey);

  @override
  bool get isDirty => localRevision != syncedRevision;

  @override
  int captureRevision() => localRevision;

  /// The payload and revision describing it share one Hive batch. A process
  /// death can therefore never leave changed progress with a clean revision.
  Future<void> _putDurable(String key, String value) async {
    _guardWrite();
    final revision = localRevision + 1;
    await _box.putAll({key: value, _localRevisionKey: '$revision'});
    _notifyChanged();
  }

  void _guardWrite() {
    if (ownerRecordCorrupt) {
      throw const StorageWriteBlockedException(
        StorageWriteBlockReason.recoveryRequired,
      );
    }
    final localOwner = owner;
    if (localOwner == null) return;
    if (!localOwner.restoreComplete) {
      throw const StorageWriteBlockedException(
        StorageWriteBlockReason.restoreIncomplete,
      );
    }
    if (localOwner.recoveryRequired) {
      throw const StorageWriteBlockedException(
        StorageWriteBlockReason.recoveryRequired,
      );
    }
    final currentUserId = _currentUserId();
    // No session means offline play against the last owner remains available.
    if (currentUserId != null && currentUserId != localOwner.uid) {
      throw const StorageWriteBlockedException(
        StorageWriteBlockReason.ownerMismatch,
      );
    }
  }

  @override
  Future<bool> markPushed(int capturedRevision) async {
    final localOwner = owner;
    final cleared = localRevision == capturedRevision;
    await _box.putAll({
      _syncedRevisionKey: '$capturedRevision',
      if (localOwner != null)
        _ownerKey: jsonEncode(localOwner
            .copyWith(snapshotRevision: localOwner.snapshotRevision + 1)
            .toJson()),
    });
    return cleared;
  }

  @override
  Future<void> discardStaleDirty() async {
    await _box.put(_syncedRevisionKey, '$localRevision');
  }

  @override
  Future<void> recordClaim(
    String uid, {
    required int snapshotRevision,
  }) async {
    final existing = owner;
    await _box.put(
      _ownerKey,
      jsonEncode(LocalOwner(
        uid: uid,
        snapshotRevision: snapshotRevision,
        restoreComplete: existing?.restoreComplete ?? true,
        recoveryRequired: existing?.recoveryRequired ?? false,
        claimed: true,
      ).toJson()),
    );
  }

  /// Rebind is the only non-restore operation allowed to clear recovery. It is
  /// used only after a new anonymous session has been created successfully.
  @override
  Future<void> rebindOwner(
    String uid, {
    int snapshotRevision = 0,
    bool claimed = false,
  }) async {
    await _box.putAll({
      _ownerKey: jsonEncode(LocalOwner(
        uid: uid,
        snapshotRevision: snapshotRevision,
        restoreComplete: true,
        recoveryRequired: false,
        claimed: claimed,
      ).toJson()),
      _syncedRevisionKey: '$localRevision',
    });
  }

  @override
  Future<void> markRecoveryRequired(
    String uid, {
    required int snapshotRevision,
  }) async {
    final existing = owner;
    await _box.put(
      _ownerKey,
      jsonEncode(LocalOwner(
        uid: uid,
        snapshotRevision: snapshotRevision,
        restoreComplete: existing?.restoreComplete ?? true,
        recoveryRequired: true,
        claimed: existing?.claimed ?? false,
      ).toJson()),
    );
  }

  /// Written before staging or promoting any live key. Completion is a second
  /// owner write after promotion, so same-uid reloads are crash-safe too.
  @override
  Future<void> startRestore(
    String uid, {
    required int snapshotRevision,
  }) async {
    await _box.put(
      _ownerKey,
      jsonEncode(LocalOwner(
        uid: uid,
        snapshotRevision: snapshotRevision,
        restoreComplete: false,
        recoveryRequired: owner?.recoveryRequired ?? false,
        claimed: true,
      ).toJson()),
    );
  }

  @override
  Future<void> finishRestore(
    String uid, {
    required int snapshotRevision,
  }) async {
    await rebindOwner(uid, snapshotRevision: snapshotRevision, claimed: true);
  }

  @override
  Future<void> stageRestore({
    required PlayerProfile profile,
    required Map<Difficulty, LifetimeStats> stats,
    required List<DayResult> history,
  }) async {
    await _box.putAll({
      _stageProfileKey: jsonEncode(profile.toJson()),
      _stageStatsKey: jsonEncode({
        for (final entry in stats.entries) entry.key.name: entry.value.toJson(),
      }),
      _stageHistoryKey: jsonEncode(history.map((e) => e.toJson()).toList()),
    });
  }

  @override
  Future<void> promoteStagedRestore() async {
    final profile = _box.get(_stageProfileKey);
    final stats = _box.get(_stageStatsKey);
    final history = _box.get(_stageHistoryKey);
    if (profile == null || stats == null || history == null) {
      throw StateError('No staged restore.');
    }
    final decodedStats = Map<String, dynamic>.from(jsonDecode(stats) as Map);
    final accountKeys = _box.keys
        .where((key) => key is String && !_installKeys.contains(key))
        .cast<String>()
        .toList();
    await _box.deleteAll(accountKeys);
    await _box.putAll({
      _profileKey: profile,
      _historyKey: history,
      for (final difficulty in Difficulty.values)
        _statsKey(difficulty): jsonEncode(decodedStats[difficulty.name]),
      _syncedRevisionKey: '$localRevision',
    });
  }

  @override
  void addChangeListener(StorageChangeListener listener) =>
      _listeners.add(listener);

  @override
  void removeChangeListener(StorageChangeListener listener) =>
      _listeners.remove(listener);

  void _notifyChanged() {
    _onChanged?.call();
    for (final listener in List<StorageChangeListener>.of(_listeners)) {
      listener();
    }
  }

  @override
  GameSnapshot? loadSnapshot(String date, Difficulty difficulty) {
    final raw = _box.get(_snapshotKey(date, difficulty));
    if (raw == null) return null;
    try {
      return GameSnapshot.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveSnapshot(GameSnapshot snapshot) async {
    _guardWrite();
    await _box.put(
      _snapshotKey(snapshot.date, snapshot.difficulty),
      jsonEncode(snapshot.toJson()),
    );
  }

  @override
  LifetimeStats loadStats(Difficulty difficulty) {
    final raw = _box.get(_statsKey(difficulty));
    if (raw == null) return LifetimeStats.empty;
    try {
      return LifetimeStats.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return LifetimeStats.empty;
    }
  }

  @override
  Future<void> saveStats(Difficulty difficulty, LifetimeStats stats) =>
      _putDurable(_statsKey(difficulty), jsonEncode(stats.toJson()));

  @override
  PlayerProfile loadProfile() {
    final raw = _box.get(_profileKey);
    if (raw == null) return PlayerProfile.empty;
    try {
      return PlayerProfile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return PlayerProfile.empty;
    }
  }

  @override
  Future<void> saveProfile(PlayerProfile profile) =>
      _putDurable(_profileKey, jsonEncode(profile.toJson()));

  @override
  Future<int> addCoins(int delta) async {
    final updated = loadProfile().creditCoins(delta);
    await saveProfile(updated);
    return updated.wallet.coins;
  }

  @override
  List<DayResult> loadHistory() {
    final raw = _box.get(_historyKey);
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => DayResult.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> appendResult(DayResult result) async {
    final history = List<DayResult>.of(loadHistory())..add(result);
    await replaceHistory(history);
  }

  @override
  Future<void> replaceHistory(List<DayResult> history) async {
    final retained = history.length <= kHistoryRetentionDays
        ? history
        : history.sublist(history.length - kHistoryRetentionDays);
    await _putDurable(
      _historyKey,
      jsonEncode(retained.map((e) => e.toJson()).toList()),
    );
  }

  @override
  Future<void> wipeAccountData() async {
    final accountKeys = _box.keys
        .where((key) => key is String && !_installKeys.contains(key))
        .cast<String>()
        .toList();
    await _box.deleteAll(accountKeys);
  }

  @override
  Future<void> wipeAll() async {
    await _box.clear();
    await _box.putAll({
      _deviceIdKey: generateDeviceId(),
      _localRevisionKey: '0',
      _syncedRevisionKey: '0',
    });
  }
}
