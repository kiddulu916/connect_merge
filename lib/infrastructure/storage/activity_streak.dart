class ActivityStreak {
  final int dailyActiveStreak;
  final String? lastActiveDate;

  const ActivityStreak({
    this.dailyActiveStreak = 0,
    this.lastActiveDate,
  });

  ActivityStreak copyWith({
    int? dailyActiveStreak,
    String? lastActiveDate,
  }) =>
      ActivityStreak(
        dailyActiveStreak: dailyActiveStreak ?? this.dailyActiveStreak,
        lastActiveDate: lastActiveDate ?? this.lastActiveDate,
      );
}
