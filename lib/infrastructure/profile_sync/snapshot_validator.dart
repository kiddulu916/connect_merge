import 'dart:convert';

import '../../domain/models/day_result.dart';
import '../../domain/models/difficulty.dart';
import '../profile_sync_service.dart'
    show SnapshotOutcome, kMaxProfileSnapshotBytes, kProfileSchemaVersion;
import '../storage_service.dart';

/// A raw cloud snapshot JSON map, parsed and type-checked into the concrete
/// domain objects it represents. Extracted from ProfileSyncService — pure,
/// with no dependency on sync state (unlike the rest of that class, which is
/// one cohesive claim/arm/push state machine).
class ValidatedSnapshot {
  final PlayerProfile profile;
  final Map<Difficulty, LifetimeStats> stats;
  final List<DayResult> history;

  const ValidatedSnapshot({
    required this.profile,
    required this.stats,
    required this.history,
  });
}

/// Returns null when [snapshot] is valid (in which case [validateSnapshot]
/// will succeed), otherwise the specific reason it was rejected.
SnapshotOutcome? snapshotValidationOutcome(Map<String, dynamic> snapshot) {
  if (utf8.encode(jsonEncode(snapshot)).length > kMaxProfileSnapshotBytes) {
    return SnapshotOutcome.oversized;
  }
  final version = snapshot['schema_version'];
  if (version is int && version > kProfileSchemaVersion) {
    return SnapshotOutcome.newerVersion;
  }
  try {
    validateSnapshot(snapshot);
    return null;
  } catch (_) {
    return SnapshotOutcome.corrupt;
  }
}

/// Parses and validates [snapshot], throwing a [FormatException] if it
/// doesn't match the expected shape.
ValidatedSnapshot validateSnapshot(Map<String, dynamic> snapshot) {
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
  return ValidatedSnapshot(profile: profile, stats: stats, history: history);
}
