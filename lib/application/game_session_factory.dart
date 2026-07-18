import '../domain/models/difficulty.dart';
import '../domain/models/move.dart';
import '../infrastructure/leaderboard_service.dart';
import '../infrastructure/storage_service.dart';
import 'engagement_cubit.dart';
import 'game_cubit.dart';
import 'loot_cubit.dart';

/// Builds production game sessions and owns their application-service bridges.
class GameSessionFactory {
  final StorageService storage;
  final EngagementCubit engagement;
  final LootCubit loot;
  final LeaderboardService? leaderboard;
  final void Function(Object error, StackTrace? stack, {bool fatal})? onError;
  final void Function(String name, [Map<String, Object?>? params])?
      onAnalyticsEvent;
  final String Function() todayProvider;

  GameSessionFactory({
    required this.storage,
    required this.engagement,
    required this.loot,
    this.leaderboard,
    this.onError,
    this.onAnalyticsEvent,
    String Function()? todayProvider,
  }) : todayProvider = todayProvider ?? utcToday;

  GameCubit create({
    required Difficulty difficulty,
    Future<void> Function()? afterCompleted,
  }) =>
      GameCubit(
        storage: storage,
        todayProvider: todayProvider,
        onTierCompleted: ({int score = 0, int highestTier = 0}) async {
          await engagement.onTierCompleted(
            date: todayProvider(),
            score: score,
            highestTier: highestTier,
          );
          await afterCompleted?.call();
        },
        onCoinsEarned: (delta) async {
          if (delta == 0) return;
          await storage.addCoins(delta);
          loot.load();
        },
        onSubmitRun: leaderboard == null ? null : _submitRun,
        onError: onError,
        onAnalyticsEvent: onAnalyticsEvent,
      )..init(difficulty: difficulty);

  Future<void> _submitRun({
    required String date,
    required Difficulty difficulty,
    required List<MoveEvent> moveLog,
    required int adContinues,
  }) =>
      leaderboard!.submitRun(
        date: date,
        difficulty: difficulty,
        moveLog: moveLog,
      );
}
