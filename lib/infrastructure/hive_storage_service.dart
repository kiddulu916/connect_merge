import 'dart:convert';

import 'package:hive/hive.dart';

import '../domain/constants.dart';
import '../domain/models/day_result.dart';
import '../domain/models/difficulty.dart';
import 'storage_service.dart';

/// Hive-backed persistence. Values are stored as JSON strings to avoid
/// generated TypeAdapters — the payloads are small and this keeps the build
/// toolchain simple (no build_runner).
///
/// Keys are per-tier:
///  - snapshot: `"$date:${difficulty.name}"`
///  - stats:    `"stats:${difficulty.name}"`
class HiveStorageService implements StorageService {
  static const _boxName = 'connect_merge';

  late Box<String> _box;

  static String _snapshotKey(String date, Difficulty difficulty) =>
      '$date:${difficulty.name}';

  static String _statsKey(Difficulty difficulty) => 'stats:${difficulty.name}';

  static const _profileKey = 'profile';

  /// History is stored as a single JSON array string under this key. Small
  /// (capped at [kHistoryRetentionDays] compact records) so a single read/write
  /// is fine and keeps us TypeAdapter-free like the other payloads.
  static const _historyKey = 'history';

  @override
  Future<void> init() async {
    _box = await Hive.openBox<String>(_boxName);
  }

  @override
  GameSnapshot? loadSnapshot(String date, Difficulty difficulty) {
    final raw = _box.get(_snapshotKey(date, difficulty));
    if (raw == null) return null;
    try {
      return GameSnapshot.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // Corrupt or pre-tier-schema snapshot: treat as missing (migration-free).
      return null;
    }
  }

  @override
  Future<void> saveSnapshot(GameSnapshot snapshot) async {
    await _box.put(_snapshotKey(snapshot.date, snapshot.difficulty),
        jsonEncode(snapshot.toJson()));
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
  Future<void> saveStats(Difficulty difficulty, LifetimeStats stats) async {
    await _box.put(_statsKey(difficulty), jsonEncode(stats.toJson()));
  }

  @override
  PlayerProfile loadProfile() {
    final raw = _box.get(_profileKey);
    if (raw == null) return PlayerProfile.empty;
    try {
      return PlayerProfile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // Corrupt profile: treat as empty (migration-free).
      return PlayerProfile.empty;
    }
  }

  @override
  Future<void> saveProfile(PlayerProfile profile) async {
    await _box.put(_profileKey, jsonEncode(profile.toJson()));
  }

  @override
  Future<int> addCoins(int delta) async {
    final profile = loadProfile();
    final updated = profile.creditCoins(delta);
    await saveProfile(updated);
    return updated.wallet.coins;
  }

  @override
  List<DayResult> loadHistory() {
    final raw = _box.get(_historyKey);
    // Absent (pre-Phase-4) or corrupt: empty list (migration-free).
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
    // Cap to the retention window, dropping the oldest entries.
    while (history.length > kHistoryRetentionDays) {
      history.removeAt(0);
    }
    await _box.put(
        _historyKey, jsonEncode(history.map((e) => e.toJson()).toList()));
  }

  @override
  Future<void> wipeAll() async {
    await _box.clear();
  }
}
