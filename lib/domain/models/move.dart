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
      default:
        throw ArgumentError('Unknown MoveEvent type: $type');
    }
  }
}

/// An accepted merge: tile at cell [from] fused into the tile at cell [to].
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
