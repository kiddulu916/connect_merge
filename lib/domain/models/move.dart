/// Ordered move-sequence recording.
///
/// A [MoveEvent] log captures exactly the player inputs that change board state,
/// in order: each accepted merge and each ad-continue. Drops are NOT logged —
/// they are regenerated deterministically from the seed. This log is unused by
/// Phase 1 UI but is the authoritative input for Phase 2's server-side replay
/// verification.
sealed class MoveEvent {
  const MoveEvent();

  Map<String, dynamic> toJson();

  static MoveEvent fromJson(Map<String, dynamic> j) {
    final type = j['type'] as String;
    switch (type) {
      case MergeEvent.type:
        return MergeEvent(from: j['from'] as int, to: j['to'] as int);
      case ContinueEvent.type:
        return const ContinueEvent();
      case ChainEvent.type:
        return ChainEvent(
          path: (j['path'] as List).map((e) => e as int).toList(),
        );
      default:
        throw ArgumentError('Unknown MoveEvent type: $type');
    }
  }
}

/// Legacy, server-rejected merge event — retained for log-format compatibility
/// and the rejection sentinel.
class MergeEvent extends MoveEvent {
  static const type = 'merge';

  final int from;
  final int to;

  const MergeEvent({required this.from, required this.to});

  @override
  Map<String, dynamic> toJson() => {'type': type, 'from': from, 'to': to};

  @override
  bool operator ==(Object other) =>
      other is MergeEvent && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(type, from, to);

  @override
  String toString() => 'MergeEvent(from: $from, to: $to)';
}

/// An accepted Connect-Merge collapse: an ordered run of orthogonally-adjacent
/// same-tier cells, collapsed onto the LAST cell (the release endpoint). A
/// 2-element path is exactly the legacy pairwise merge. This is the authoritative
/// replay input; the server re-validates the path geometry against the seeded
/// board, so a forged path is rejected.
class ChainEvent extends MoveEvent {
  static const type = 'chain';

  final List<int> path;

  const ChainEvent({required this.path});

  @override
  Map<String, dynamic> toJson() => {'type': type, 'path': path};

  @override
  bool operator ==(Object other) =>
      other is ChainEvent &&
      other.path.length == path.length &&
      _eq(other.path, path);

  static bool _eq(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(path);

  @override
  String toString() => 'ChainEvent(path: $path)';
}

/// An ad-continue was granted (+kAdMoveReward moves).
class ContinueEvent extends MoveEvent {
  static const type = 'continue';

  const ContinueEvent();

  @override
  Map<String, dynamic> toJson() => {'type': type};

  @override
  bool operator ==(Object other) => other is ContinueEvent;

  @override
  int get hashCode => type.hashCode;

  @override
  String toString() => 'ContinueEvent()';
}
