/// A live tile. [id] is a stable identity used as the widget key so the UI can
/// animate a tile as it slides/merges. [tier] is 1..kMaxTier; value is 2^tier.
///
/// [golden] (Phase 1) marks a deterministically seed-chosen drop as golden:
/// merging it credits bonus coins to the client-side wallet. It is a purely
/// visual/economy flag and NEVER affects `score` or the move log.
class Tile {
  final int id;
  final int tier;
  final bool golden;

  const Tile({required this.id, required this.tier, this.golden = false});

  int get value => 1 << tier;

  Tile copyWith({int? tier, bool? golden}) =>
      Tile(id: id, tier: tier ?? this.tier, golden: golden ?? this.golden);

  Map<String, dynamic> toJson() => {
        'id': id,
        'tier': tier,
        // Migration-free: only persist when set so pre-Phase-1 snapshots and
        // non-golden tiles stay byte-compatible.
        if (golden) 'golden': true,
      };

  static Tile fromJson(Map<String, dynamic> j) => Tile(
        id: j['id'] as int,
        tier: j['tier'] as int,
        // Absent ⇒ false (migration-free).
        golden: (j['golden'] as bool?) ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is Tile &&
      other.id == id &&
      other.tier == tier &&
      other.golden == golden;

  @override
  int get hashCode => Object.hash(id, tier, golden);
}
