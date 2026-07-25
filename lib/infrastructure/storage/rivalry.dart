class Rivalry {
  final String? rivalId;
  final String? rivalName;
  final Map<String, int> lastSeenRivalScoreByTier;

  const Rivalry({
    this.rivalId,
    this.rivalName,
    this.lastSeenRivalScoreByTier = const {},
  });

  Rivalry copyWith({
    String? rivalId,
    String? rivalName,
    Map<String, int>? lastSeenRivalScoreByTier,
  }) =>
      Rivalry(
        rivalId: rivalId ?? this.rivalId,
        rivalName: rivalName ?? this.rivalName,
        lastSeenRivalScoreByTier:
            lastSeenRivalScoreByTier ?? this.lastSeenRivalScoreByTier,
      );
}
