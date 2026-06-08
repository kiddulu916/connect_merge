import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../application/engagement_cubit.dart';
import '../../application/game_cubit.dart';
import '../../domain/models/difficulty.dart';
import '../../infrastructure/ad_service.dart';
import '../../infrastructure/friends_service.dart';
import '../../infrastructure/leaderboard_service.dart';
import '../../infrastructure/notification_service.dart';
import '../../infrastructure/storage_service.dart';
import '../theme/tile_palette.dart';
import '../widgets/streak_banner.dart';
import 'achievements_screen.dart';
import 'cosmetics_screen.dart';
import 'friends_screen.dart';
import 'game_screen.dart';
import 'leaderboard_screen.dart';
import 'practice_screen.dart';

/// Entry screen: pick a difficulty tier. Each card shows the starting tile
/// count, whether the tier is already done today, and a live countdown to the
/// 00:00 UTC reset.
class TierSelectScreen extends StatefulWidget {
  final StorageService storage;
  final AdService adService;

  /// Online leaderboard service. Null when offline / Supabase not configured —
  /// the leaderboard entry points are then hidden.
  final LeaderboardService? leaderboard;

  /// Friends service. Null when offline — the Friends entry point and the
  /// Global/Friends toggle are then hidden.
  final FriendsService? friends;

  /// Phase 4 retention orchestration (streaks, achievements, cosmetics). When
  /// null (tests), a local cubit is created from [storage].
  final EngagementCubit? engagement;

  /// Local notification scheduler. Null in tests / when unavailable.
  final NotificationService? notifications;

  /// Override for tests; defaults to the real UTC date string.
  final String Function()? todayProvider;

  /// Override for tests to intercept tier selection instead of pushing the
  /// game route (which would load the ad plugin). When null, pushes GameScreen.
  final void Function(BuildContext context, Difficulty difficulty)?
      onTierSelected;

  const TierSelectScreen({
    super.key,
    required this.storage,
    required this.adService,
    this.leaderboard,
    this.friends,
    this.engagement,
    this.notifications,
    this.todayProvider,
    this.onTierSelected,
  });

  String today() => (todayProvider ?? utcToday)();

  @override
  State<TierSelectScreen> createState() => _TierSelectScreenState();
}

class _TierSelectScreenState extends State<TierSelectScreen> {
  Timer? _ticker;
  Duration _untilReset = Duration.zero;

  /// Cached so the share screen can offer an invite link without an extra RPC.
  String? _friendCode;

  /// Engagement cubit (provided, or created locally for tests). Owned locally
  /// only when we created it.
  late final EngagementCubit _engagement;
  bool _ownsEngagement = false;

  @override
  void initState() {
    super.initState();
    _engagement = widget.engagement ??
        (EngagementCubit(
            storage: widget.storage, todayProvider: widget.todayProvider)
          ..load());
    _ownsEngagement = widget.engagement == null;
    _untilReset = _computeUntilReset();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _untilReset = _computeUntilReset());
    });
    _loadFriendCode();
    // On app-open: reschedule the daily reminder based on current state.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _rescheduleNotifications());
  }

  Future<void> _loadFriendCode() async {
    final friends = widget.friends;
    if (friends == null) return;
    try {
      final code = await friends.myFriendCode();
      if (mounted) setState(() => _friendCode = code);
    } catch (_) {
      // Offline; share card simply omits the invite link.
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    if (_ownsEngagement) _engagement.close();
    super.dispose();
  }

  /// True when every tier's day is already completed.
  bool _allTiersDoneToday() =>
      Difficulty.values.every(_isCompleted);

  /// Reschedule the daily reminder + streak-expiry warning. No-op without a
  /// notification service or when permission isn't granted yet (the plan is
  /// still computed but the plugin gracefully ignores undelivered schedules).
  Future<void> _rescheduleNotifications() async {
    final notif = widget.notifications;
    if (notif == null) return;
    final profile = widget.storage.loadProfile();
    final streak = profile.dailyActiveStreak;
    final today = widget.today();
    // Streak is at risk if there's an active streak that hasn't advanced today.
    final atRisk = streak > 0 && profile.lastActiveDate != today;
    try {
      await notif.reschedule(
        now: tz.TZDateTime.now(tz.local),
        reminderMinutes: profile.reminderMinutes,
        enabled: profile.notificationsEnabled,
        allTiersDoneToday: _allTiersDoneToday(),
        streakAtRisk: atRisk,
      );
    } catch (_) {
      // Notifications are best-effort; never block the UI.
    }
  }

  Duration _computeUntilReset() {
    final now = DateTime.now().toUtc();
    final nextMidnight = DateTime.utc(now.year, now.month, now.day)
        .add(const Duration(days: 1));
    return nextMidnight.difference(now);
  }

  String _fmt(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  bool _isCompleted(Difficulty d) {
    final today = widget.today();
    return widget.storage.loadSnapshot(today, d)?.completed ?? false;
  }

  void _openLeaderboard(BuildContext context, Difficulty difficulty) {
    final service = widget.leaderboard;
    if (service == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LeaderboardScreen(
          service: service,
          friendsService: widget.friends,
          initialDifficulty: difficulty,
          todayProvider: widget.todayProvider,
        ),
      ),
    );
  }

  /// Main-menu entry point: open the leaderboard when online, otherwise explain
  /// why it's unavailable. Always reachable so there's a visible button.
  void _openLeaderboardOrExplain(BuildContext context) {
    if (widget.leaderboard == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Leaderboards need an internet connection.')),
      );
      return;
    }
    _openLeaderboard(context, Difficulty.values.first);
  }

  void _openFriends(BuildContext context) {
    final service = widget.friends;
    if (service == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FriendsScreen(
          service: service,
          todayProvider: widget.today,
        ),
      ),
    );
  }

  void _startTier(BuildContext context, Difficulty difficulty) {
    final override = widget.onTierSelected;
    if (override != null) {
      override(context, difficulty);
      return;
    }
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => BlocProvider(
              create: (_) => GameCubit(
                storage: widget.storage,
                todayProvider: widget.todayProvider,
                onTierCompleted: _onTierCompleted,
              )..init(difficulty: difficulty),
              child: GameScreen(
                adService: widget.adService,
                engagement: _engagement,
                notifications: widget.notifications,
                friendCode: _friendCode,
              ),
            ),
          ),
        )
        .then((_) {
          if (mounted) setState(() {}); // refresh "done today" badges
          _rescheduleNotifications();
        });
  }

  /// Completion hook fired by [GameCubit] when a tier's day is locked: advance
  /// the headline streak / achievements / cosmetics, then reschedule the
  /// reminder (suppressed once all tiers are done).
  Future<void> _onTierCompleted() async {
    await _engagement.onTierCompleted(date: widget.today());
    await _maybeRequestPermissionThenReschedule();
  }

  /// Request notification permission CONTEXTUALLY (after the first completion),
  /// then (re)schedule. Only prompts once: marks notifications enabled in the
  /// profile when granted.
  Future<void> _maybeRequestPermissionThenReschedule() async {
    final notif = widget.notifications;
    if (notif == null) return;
    var profile = widget.storage.loadProfile();
    if (!profile.notificationsEnabled) {
      bool granted = false;
      try {
        granted = await notif.requestPermission();
      } catch (_) {
        granted = false;
      }
      if (granted) {
        profile = profile.copyWith(notificationsEnabled: true);
        await widget.storage.saveProfile(profile);
      }
    }
    await _rescheduleNotifications();
  }

  void _openAchievements(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AchievementsScreen(unlocked: _engagement.state.unlocked),
      ),
    );
  }

  void _openCosmetics(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CosmeticsScreen(
          engagement: _engagement,
          adService: widget.adService,
        ),
      ),
    );
  }

  void _watchFreezeAd(BuildContext context) {
    widget.adService.showRewarded(
      onReward: () async {
        final granted = await _engagement.grantFreezeToken();
        if (granted && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Streak freeze earned!')),
          );
        }
      },
      onUnavailable: () {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No ad available right now.')),
          );
        }
      },
    );
  }

  void _openPractice(BuildContext context, Difficulty difficulty) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PracticeScreen(
          difficulty: difficulty,
          adService: widget.adService,
          cosmetic: _engagement.state.selectedCosmetic,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF12141C),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Stack(
                alignment: Alignment.center,
                children: [
                  const Text('Merge Loop',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 32,
                          fontWeight: FontWeight.w900)),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: const Key('open-achievements'),
                          tooltip: 'Achievements',
                          icon: const Icon(Icons.emoji_events,
                              color: Colors.white70),
                          onPressed: () => _openAchievements(context),
                        ),
                        IconButton(
                          key: const Key('open-cosmetics'),
                          tooltip: 'Tile themes',
                          icon: const Icon(Icons.palette, color: Colors.white70),
                          onPressed: () => _openCosmetics(context),
                        ),
                        if (widget.friends != null)
                          IconButton(
                            key: const Key('open-friends'),
                            tooltip: 'Friends',
                            icon: const Icon(Icons.group, color: Colors.white70),
                            onPressed: () => _openFriends(context),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              BlocBuilder<EngagementCubit, EngagementState>(
                bloc: _engagement,
                builder: (context, eng) {
                  if (eng.dailyActiveStreak <= 0) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: StreakBanner(
                      streak: eng.dailyActiveStreak,
                      freezeTokens: eng.freezeTokens,
                      onFreeze: () => _watchFreezeAd(context),
                    ),
                  );
                },
              ),
              const SizedBox(height: 4),
              const Text('Choose your daily challenge',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 14)),
              const SizedBox(height: 8),
              Text('Resets in ${_fmt(_untilReset)} (UTC)',
                  key: const Key('reset-countdown'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 12,
                      letterSpacing: 1)),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('open-leaderboard-menu'),
                onPressed: () => _openLeaderboardOrExplain(context),
                icon: const Icon(Icons.leaderboard),
                label: const Text('Leaderboard'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white24),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: ListView(
                  children: [
                    for (final d in Difficulty.values) _tierCard(context, d),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tierCard(BuildContext context, Difficulty d) {
    final completed = _isCompleted(d);
    // Use the tier's starting fill to pick a representative accent color.
    final accent = TilePalette.colorForTier(d.startingFill);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Material(
        color: const Color(0xFF1B1E2A),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: Key('tier-${d.name}'),
          borderRadius: BorderRadius.circular(16),
          onTap: completed ? null : () => _startTier(context, d),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: completed ? 0.3 : 1.0),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: Text('${d.startingFill}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d.label,
                          style: TextStyle(
                              color: completed ? Colors.white54 : Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text('${d.startingFill} starting tiles',
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 13)),
                    ],
                  ),
                ),
                IconButton(
                  key: Key('practice-${d.name}'),
                  tooltip: 'Practice',
                  icon:
                      const Icon(Icons.fitness_center, color: Colors.white54),
                  onPressed: () => _openPractice(context, d),
                ),
                if (widget.leaderboard != null)
                  IconButton(
                    key: Key('leaderboard-${d.name}'),
                    tooltip: 'Leaderboard',
                    icon: const Icon(Icons.leaderboard, color: Colors.white54),
                    onPressed: () => _openLeaderboard(context, d),
                  ),
                if (completed)
                  const Text('Done today ✓',
                      style: TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 13,
                          fontWeight: FontWeight.w700))
                else
                  const Icon(Icons.chevron_right, color: Colors.white54),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
