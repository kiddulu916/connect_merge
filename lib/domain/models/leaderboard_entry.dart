/// A single row in a daily per-tier leaderboard, as returned by the
/// `leaderboard(p_date, p_diff, p_limit)` RPC.
class LeaderboardEntry {
  final int rank;
  final String displayName;
  final int score;

  /// True when this row belongs to the current player (for highlight).
  final bool isMe;

  /// The row's player id, when the RPC exposes it. Only the friends daily board
  /// (`friends_leaderboard`) returns it — used to match a chosen rival by id.
  /// Null on the global board and all period boards.
  final String? playerId;

  const LeaderboardEntry({
    required this.rank,
    required this.displayName,
    required this.score,
    required this.isMe,
    this.playerId,
  });

  /// Maps a row from the `leaderboard`/`friends_leaderboard` RPCs. The RPCs
  /// return snake_case columns (`rank`, `display_name`, `score`, `is_me`); the
  /// friends daily board additionally returns `player_id`.
  static LeaderboardEntry fromJson(Map<String, dynamic> j) => LeaderboardEntry(
        rank: (j['rank'] as num).toInt(),
        displayName: j['display_name'] as String,
        score: (j['score'] as num).toInt(),
        isMe: (j['is_me'] as bool?) ?? false,
        playerId: j['player_id'] as String?,
      );

  /// Maps a row from a period RPC (`leaderboard_period`,
  /// `friends_leaderboard_period`). Same shape as [fromJson] except the summed
  /// score column is named `total` rather than `score`. Period boards carry no
  /// `player_id`.
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
      other.isMe == isMe &&
      other.playerId == playerId;

  @override
  int get hashCode => Object.hash(rank, displayName, score, isMe, playerId);

  @override
  String toString() =>
      'LeaderboardEntry(rank: $rank, displayName: $displayName, score: $score, isMe: $isMe, playerId: $playerId)';
}
