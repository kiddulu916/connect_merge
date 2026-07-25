import '../../domain/models/weekly_prize.dart';

class PrizeLedger {
  final String? lastDailyPrizeDate;
  final String? lastWeeklyPrizeDate;
  final String? lastMonthlyPrizeMonth;
  final String? lastChallengeCheckDate;
  final List<WeeklyPrize> weeklyPrizes;

  const PrizeLedger({
    this.lastDailyPrizeDate,
    this.lastWeeklyPrizeDate,
    this.lastMonthlyPrizeMonth,
    this.lastChallengeCheckDate,
    this.weeklyPrizes = const [],
  });

  PrizeLedger copyWith({
    String? lastDailyPrizeDate,
    String? lastWeeklyPrizeDate,
    String? lastMonthlyPrizeMonth,
    String? lastChallengeCheckDate,
    List<WeeklyPrize>? weeklyPrizes,
  }) =>
      PrizeLedger(
        lastDailyPrizeDate: lastDailyPrizeDate ?? this.lastDailyPrizeDate,
        lastWeeklyPrizeDate: lastWeeklyPrizeDate ?? this.lastWeeklyPrizeDate,
        lastMonthlyPrizeMonth:
            lastMonthlyPrizeMonth ?? this.lastMonthlyPrizeMonth,
        lastChallengeCheckDate:
            lastChallengeCheckDate ?? this.lastChallengeCheckDate,
        weeklyPrizes: weeklyPrizes ?? this.weeklyPrizes,
      );
}
