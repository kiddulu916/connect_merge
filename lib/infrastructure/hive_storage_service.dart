import 'dart:convert';

import 'package:hive/hive.dart';

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
  static const _boxName = 'merge_loop';

  late Box<String> _box;

  static String _snapshotKey(String date, Difficulty difficulty) =>
      '$date:${difficulty.name}';

  static String _statsKey(Difficulty difficulty) => 'stats:${difficulty.name}';

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
}
