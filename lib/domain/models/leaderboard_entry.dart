/// A single row in a daily per-tier leaderboard, as returned by the
/// `leaderboard(p_date, p_diff, p_limit)` RPC.
class LeaderboardEntry {
  final int rank;
  final String displayName;
  final int score;

  /// True when this row belongs to the current player (for highlight).
  final bool isMe;

  const LeaderboardEntry({
    required this.rank,
    required this.displayName,
    required this.score,
    required this.isMe,
  });

  /// Maps a row from the `leaderboard` RPC. The RPC returns snake_case columns
  /// (`rank`, `display_name`, `score`, `is_me`).
  static LeaderboardEntry fromJson(Map<String, dynamic> j) => LeaderboardEntry(
        rank: (j['rank'] as num).toInt(),
        displayName: j['display_name'] as String,
        score: (j['score'] as num).toInt(),
        isMe: (j['is_me'] as bool?) ?? false,
      );

  /// Maps a row from a period RPC (`leaderboard_period`,
  /// `friends_leaderboard_period`). Same shape as [fromJson] except the summed
  /// score column is named `total` rather than `score`.
  static LeaderboardEntry fromPeriodJson(Map<String, dynamic> j) =>
      LeaderboardEntry(
        rank: (j['rank'] as num).toInt(),
        displayName: j['display_name'] as String,
        score: (j['total'] as num).toInt(),
        isMe: (j['is_me'] as bool?) ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is LeaderboardEntry &&
      other.rank == rank &&
      other.displayName == displayName &&
      other.score == score &&
      other.isMe == isMe;

  @override
  int get hashCode => Object.hash(rank, displayName, score, isMe);

  @override
  String toString() =>
      'LeaderboardEntry(rank: $rank, displayName: $displayName, score: $score, isMe: $isMe)';
}
