import 'dart:convert';

import 'package:hive/hive.dart';

import 'storage_service.dart';

/// Hive-backed persistence. Values are stored as JSON strings to avoid
/// generated TypeAdapters — the payloads are small and this keeps the build
/// toolchain simple (no build_runner).
class HiveStorageService implements StorageService {
  static const _boxName = 'merge_loop';
  static const _snapshotKey = 'snapshot';
  static const _statsKey = 'stats';

  late Box<String> _box;

  @override
  Future<void> init() async {
    _box = await Hive.openBox<String>(_boxName);
  }

  @override
  GameSnapshot? loadSnapshot() {
    final raw = _box.get(_snapshotKey);
    if (raw == null) return null;
    return GameSnapshot.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  @override
  Future<void> saveSnapshot(GameSnapshot snapshot) async {
    await _box.put(_snapshotKey, jsonEncode(snapshot.toJson()));
  }

  @override
  LifetimeStats loadStats() {
    final raw = _box.get(_statsKey);
    if (raw == null) return LifetimeStats.empty;
    return LifetimeStats.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  @override
  Future<void> saveStats(LifetimeStats stats) async {
    await _box.put(_statsKey, jsonEncode(stats.toJson()));
  }
}
