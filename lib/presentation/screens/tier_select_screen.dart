import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../application/duel_cubit.dart';
import '../../application/engagement_cubit.dart';
import '../../application/game_cubit.dart';
import '../../application/loot_cubit.dart';
import '../../application/loot_state.dart';
import '../../application/rivalry_cubit.dart';
import '../../domain/engine/daily_seeder.dart';
import '../../domain/models/challenge_rule.dart';
import '../../domain/models/difficulty.dart';
import '../../domain/models/duel_challenge.dart';
import '../../domain/models/move.dart';
import '../../infrastructure/ad_service.dart';
import '../../infrastructure/friends_service.dart';
import '../../infrastructure/leaderboard_service.dart';
import '../../infrastructure/notification_service.dart';
import '../../infrastructure/storage_service.dart';
import '../theme/tile_palette.dart';
import '../theme/tokens.dart';
import '../widgets/coin_balance.dart';
import '../widgets/duel_banner.dart';
import '../widgets/rival_indicator.dart';
import '../widgets/streak_banner.dart';
import 'achievements_screen.dart';
import 'almanac_screen.dart';
import 'cosmetics_screen.dart';
import 'friends_screen.dart';
import 'game_screen.dart';
import 'leaderboard_screen.dart';
import 'loot_chest_screen.dart';
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

  /// Phase 1 Daily Loot Chest cubit. When null, a local cubit is created from
  /// [storage].
  final LootCubit? loot;

  /// Phase 3 rivalry cubit. When null, a local cubit is created from [storage]
  /// (owned + closed locally, mirroring [engagement]/[loot]).
  final RivalryCubit? rivalry;

  /// Phase 3 async-duel cubit. Held as-is (nullable) — never created locally,
  /// since an incoming duel rides in from a deep link via the app shell.
  final DuelCubit? duels;

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
    this.loot,
    this.rivalry,
    this.duels,
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

  /// Loot cubit (provided, or created locally). Owned locally only when created.
  late final LootCubit _loot;
  bool _ownsLoot = false;

  /// Rivalry cubit (provided, or created locally). Owned locally only when made.
  late final RivalryCubit _rivalry;
  bool _ownsRivalry = false;

  /// Duel cubit, held verbatim from the widget (never created locally; null when
  /// the social layer is off / in tests that don't pass one).
  DuelCubit? get _duelsCubit => widget.duels;

  @override
  void initState() {
    super.initState();
    _engagement = widget.engagement ??
        (EngagementCubit(
            storage: widget.storage, todayProvider: widget.todayProvider)
          ..load());
    _ownsEngagement = widget.engagement == null;
    _loot = widget.loot ??
        (LootCubit(
            storage: widget.storage, todayProvider: widget.todayProvider)
          ..load());
    _ownsLoot = widget.loot == null;
    _rivalry = widget.rivalry ?? (RivalryCubit(storage: widget.storage)..load());
    _ownsRivalry = widget.rivalry == null;
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
    if (_ownsLoot) _loot.close();
    if (_ownsRivalry) _rivalry.close();
    super.dispose();
  }

  /// True when every tier's day is already completed.
  bool _allTiersDoneToday() =>
      Difficulty.values.where((d) => d != Difficulty.challenge).every(_isCompleted);

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
        lootUnclaimed: profile.lastLootClaimDate != today,
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

  /// True once the clock passes 12:00 UTC — the challenge unlocks at noon.
  bool get _challengeUnlocked => DateTime.now().toUtc().hour >= 12;

  /// Today's challenge rule label, derived deterministically from the date.
  String get _challengeRuleLabel =>
      DailySeeder(widget.today(), Difficulty.challenge).challengeRule.label;

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
          weeklyPrizes: _engagement.state.weeklyPrizes,
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
          rivalry: _rivalry,
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
    // Capture the messenger now so settling a duel after the game returns never
    // touches a possibly-defunct BuildContext across the async navigation gap.
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => BlocProvider(
              create: (_) => GameCubit(
                storage: widget.storage,
                todayProvider: widget.todayProvider,
                onTierCompleted: _onTierCompleted,
                onCoinsEarned: _creditCoins,
                // Wired only when a leaderboard service is present; null offline
                // so the cubit's submit no-ops.
                onSubmitRun: widget.leaderboard == null ? null : _submitRun,
              )..init(difficulty: difficulty),
              child: GameScreen(
                adService: widget.adService,
                storage: widget.storage,
                engagement: _engagement,
                notifications: widget.notifications,
                friendCode: _friendCode,
              ),
            ),
          ),
        )
        .then((_) {
          if (mounted) setState(() {}); // refresh "done today" badges
          _settleDuelIfMatched(messenger, difficulty);
          _rescheduleNotifications();
        });
  }

  /// After a game returns, settle an active duel whose `(date, difficulty)`
  /// matches the just-played tier: read the completed snapshot's score and feed
  /// it to the duel cubit, then surface the win/lose/tie outcome via the
  /// captured [messenger]. The duel score is DISPLAY-ONLY — this never touches
  /// any leaderboard row.
  void _settleDuelIfMatched(
      ScaffoldMessengerState messenger, Difficulty difficulty) {
    final duels = widget.duels;
    if (duels == null) return;
    final challenge = duels.state.challenge;
    if (challenge == null) return;
    final today = widget.today();
    if (challenge.date != today || challenge.difficulty != difficulty) return;
    final score = widget.storage.loadSnapshot(today, difficulty)?.board.score;
    if (score == null) return;
    duels.recordMyResult(date: today, difficulty: difficulty, myScore: score);
    final outcome = duels.state.outcome;
    if (outcome == null) return;
    final msg = switch (outcome) {
      DuelOutcome.win => 'You won the duel!',
      DuelOutcome.lose => 'You lost the duel — rematch?',
      DuelOutcome.tie => 'The duel was a tie!',
    };
    messenger.showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Completion hook fired by [GameCubit] when a tier's day is locked: advance
  /// the headline streak / achievements / cosmetics, then reschedule the
  /// reminder (suppressed once all tiers are done).
  Future<void> _onTierCompleted({int score = 0, int highestTier = 0}) async {
    await _engagement.onTierCompleted(
      date: widget.today(),
      score: score,
      highestTier: highestTier,
    );
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

  void _openAlmanac(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AlmanacScreen(
          almanac: _engagement.state.almanac,
          lifetimeXp: _engagement.state.lifetimeXp,
          cosmetic: _engagement.state.selectedCosmetic,
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

  void _openLootChest(BuildContext context) {
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => LootChestScreen(
              loot: _loot,
              adService: widget.adService,
            ),
          ),
        )
        .then((_) {
          if (mounted) setState(() {}); // refresh coin pill / chest badge
          _rescheduleNotifications();
        });
  }

  /// Apply a signed coin [delta] to the wallet (Phase 1). Decoupled hook passed
  /// to [GameCubit]; coins never touch score. Goes through the single awaited
  /// [StorageService.addCoins] path (credit on golden merge / completion, refund
  /// on undo) so the write is durable and races/app-kill can't drop it. Refreshes
  /// the loot cubit so the coin pill reflects the new balance.
  Future<void> _creditCoins(int delta) async {
    if (delta == 0) return;
    await widget.storage.addCoins(delta);
    _loot.load();
  }

  /// Online submit hook (Phase 2) bridging [GameCubit] to the
  /// [LeaderboardService]. The client sends ONLY the move log; the server
  /// replays it to compute the authoritative score and is the sole score writer.
  /// [adContinues] is derived server-side from the log's ContinueEvents, so it
  /// is unused here. Best-effort: the cubit calls this off the result-screen
  /// critical path and swallows transport errors.
  Future<void> _submitRun({
    required String date,
    required Difficulty difficulty,
    required List<MoveEvent> moveLog,
    required int adContinues,
  }) async {
    final service = widget.leaderboard;
    if (service == null) return;
    await service.submitRun(
        date: date, difficulty: difficulty, moveLog: moveLog);
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

  /// A compact secondary-nav icon button for the top app bar. Tighter than the
  /// default 48px target (22px glyph, 40px hit area, no padding) so up to four
  /// fit alongside the title without forcing it to wrap.
  Widget _navIconButton({
    required Key iconKey,
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      key: iconKey,
      tooltip: tooltip,
      icon: Icon(icon, color: AppColors.textSecondary),
      iconSize: 22,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        minimumSize: const Size(40, 40),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Top app bar: title left, secondary-nav icons right. The title
              // uses FittedBox(scaleDown) so it always stays on ONE line —
              // shrinking only if the (up to 4) compact action icons leave it
              // too little room — and never wraps.
              Row(
                children: [
                  const Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text('Connect Merge',
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 26,
                              fontWeight: FontWeight.w900)),
                    ),
                  ),
                  _navIconButton(
                    iconKey: const Key('open-achievements'),
                    tooltip: 'Achievements',
                    icon: Icons.emoji_events,
                    onPressed: () => _openAchievements(context),
                  ),
                  _navIconButton(
                    iconKey: const Key('open-cosmetics'),
                    tooltip: 'Tile themes',
                    icon: Icons.palette,
                    onPressed: () => _openCosmetics(context),
                  ),
                  _navIconButton(
                    iconKey: const Key('open-almanac'),
                    tooltip: 'Merge Almanac',
                    icon: Icons.menu_book,
                    onPressed: () => _openAlmanac(context),
                  ),
                  if (widget.friends != null)
                    _navIconButton(
                      iconKey: const Key('open-friends'),
                      tooltip: 'Friends',
                      icon: Icons.group,
                      onPressed: () => _openFriends(context),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
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
              BlocBuilder<RivalryCubit, RivalryState>(
                bloc: _rivalry,
                builder: (context, riv) {
                  if (!riv.hasRival || riv.rivalName == null) {
                    return const SizedBox.shrink();
                  }
                  // First still-incomplete tier: my best vs the rival's last
                  // seen on that tier (display-only, never a leaderboard write).
                  final tier = Difficulty.values.firstWhere(
                    (d) => !_isCompleted(d),
                    orElse: () => Difficulty.values.first,
                  );
                  final mine = widget.storage
                          .loadSnapshot(widget.today(), tier)
                          ?.board
                          .score ??
                      0;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Center(
                      child: RivalIndicator(
                        rivalName: riv.rivalName!,
                        delta: RivalDelta(
                          myScore: mine,
                          rivalScore: riv.lastSeenFor(tier) ?? 0,
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: [
                  const Expanded(
                    child: Text('Choose your daily challenge',
                        style: TextStyle(
                            color: AppColors.textMuted, fontSize: 14)),
                  ),
                  Tooltip(
                    message: 'Resets at 00:00 UTC',
                    child: Container(
                      key: const Key('reset-countdown'),
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(AppRadii.pill),
                        border: Border.all(
                            color: AppColors.accent.withValues(alpha: 0.35)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.timer_outlined,
                              size: 14, color: AppColors.accent),
                          const SizedBox(width: 6),
                          Text('Resets in ${_fmt(_untilReset)}',
                              style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  fontFeatures: [FontFeature.tabularFigures()])),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              BlocBuilder<LootCubit, LootState>(
                bloc: _loot,
                builder: (context, loot) {
                  final ready = loot is LootReady;
                  return Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          key: const Key('open-loot-chest'),
                          onPressed: () => _openLootChest(context),
                          icon: const Icon(Icons.card_giftcard, size: 18),
                          label: Text(
                              ready ? 'Daily chest' : 'Chest claimed',
                              overflow: TextOverflow.ellipsis),
                          style: FilledButton.styleFrom(
                            backgroundColor:
                                ready ? AppColors.accent : AppColors.surface,
                            foregroundColor: AppColors.textPrimary,
                            padding: const EdgeInsets.symmetric(
                                vertical: AppSpacing.md),
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      CoinBalance(coins: loot.coins),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const Key('open-leaderboard-menu'),
                          onPressed: () => _openLeaderboardOrExplain(context),
                          icon: const Icon(Icons.leaderboard, size: 18),
                          label: const Text('Leaderboard',
                              overflow: TextOverflow.ellipsis),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.textPrimary,
                            side: const BorderSide(color: AppColors.border),
                            padding: const EdgeInsets.symmetric(
                                vertical: AppSpacing.md),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: AppSpacing.lg),
              if (widget.duels != null)
                BlocBuilder<DuelCubit, DuelState>(
                  bloc: _duelsCubit,
                  builder: (context, duel) {
                    final challenge = duel.challenge;
                    if (challenge == null) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: DuelBanner(
                        challenge: challenge,
                        expired: duel.expired,
                        onPlay: () =>
                            _startTier(context, challenge.difficulty),
                        onPlayToday: () =>
                            _startTier(context, challenge.difficulty),
                        onDismiss: () => widget.duels!.dismiss(),
                      ),
                    );
                  },
                ),
              Expanded(
                child: ListView(
                  children: [
                    for (final d in Difficulty.values
                        .where((d) => d != Difficulty.challenge))
                      Padding(
                        padding:
                            const EdgeInsets.only(bottom: AppSpacing.lg),
                        child: _TierCard(
                          difficulty: d,
                          completed: _isCompleted(d),
                          accent: TilePalette.colorForTier(d.startingFill),
                          rank: Difficulty.values.indexOf(d),
                          onTap: _isCompleted(d)
                              ? null
                              : () => _startTier(context, d),
                          onPractice: () => _openPractice(context, d),
                          onLeaderboard: widget.leaderboard == null
                              ? null
                              : () => _openLeaderboard(context, d),
                        ),
                      ),
                    _buildChallengeCard(context),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Daily Challenge card
  // ---------------------------------------------------------------------------

  static const _challengeAccent = Color(0xFF9C27B0); // deep purple / violet

  /// Builds the Daily Challenge card in one of three states:
  ///   • Locked (before noon UTC): countdown + rule teaser + lock icon
  ///   • Unlocked, not played: rule label + Play button
  ///   • Completed: Done ✓ + rule label
  Widget _buildChallengeCard(BuildContext context) {
    final unlocked = _challengeUnlocked;
    final completed = _isCompleted(Difficulty.challenge);
    final ruleName = _challengeRuleLabel;

    // --- Shared card frame ---
    Widget frame({required Widget child}) {
      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.lg),
        child: AnimatedScale(
          scale: 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Material(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadii.md),
            child: InkWell(
              key: const Key('tier-challenge'),
              borderRadius: BorderRadius.circular(AppRadii.md),
              onTap: (!unlocked || completed)
                  ? null
                  : () => _startTier(context, Difficulty.challenge),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  border: Border.all(
                    color: completed
                        ? AppColors.success.withValues(alpha: 0.45)
                        : _challengeAccent.withValues(alpha: 0.50),
                    width: 1.5,
                  ),
                ),
                padding: const EdgeInsets.all(20),
                child: child,
              ),
            ),
          ),
        ),
      );
    }

    // --- Locked state ---
    if (!unlocked) {
      final now = DateTime.now().toUtc();
      final noon = DateTime.utc(now.year, now.month, now.day, 12);
      final remaining = noon.difference(now);

      return frame(
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: _challengeAccent.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(AppRadii.sm),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.lock_clock,
                  size: 26, color: _challengeAccent),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Daily Challenge',
                      style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: AppSpacing.xs),
                  Text('Today: $ruleName',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.textMuted, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(
                    'Opens in ${_fmt(remaining)}',
                    style: const TextStyle(
                        color: _challengeAccent,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // --- Completed state ---
    if (completed) {
      return frame(
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.success.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(AppRadii.sm),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.check_circle,
                  size: 28, color: AppColors.success),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Daily Challenge',
                      style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 20,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Done today ✓  ·  $ruleName',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.success,
                        fontSize: 13,
                        fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // --- Unlocked, not yet played ---
    return frame(
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: _challengeAccent,
              borderRadius: BorderRadius.circular(AppRadii.sm),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.bolt, size: 28, color: Colors.white),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Daily Challenge',
                    style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: AppSpacing.xs),
                Text('Today: $ruleName',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textFaint, fontSize: 13)),
              ],
            ),
          ),
          FilledButton(
            key: const Key('play-challenge'),
            onPressed: () => _startTier(context, Difficulty.challenge),
            style: FilledButton.styleFrom(
              backgroundColor: _challengeAccent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Play',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

}

/// A single difficulty tier as a tappable "hero" card.
///
/// Stateful only to drive a subtle press-scale ([scale-feedback]); the InkWell
/// still supplies the ripple and is the keyed tap target the tests drive. A
/// completed card switches to a success-tinted outline + check badge and is
/// non-interactive.
class _TierCard extends StatefulWidget {
  final Difficulty difficulty;
  final bool completed;
  final Color accent;

  /// 0-based difficulty rank; drives the 1–4 pip indicator.
  final int rank;

  /// Tap handler. Null when the tier is already completed (card is inert).
  final VoidCallback? onTap;
  final VoidCallback onPractice;

  /// Opens the per-tier leaderboard; null hides the icon (offline).
  final VoidCallback? onLeaderboard;

  const _TierCard({
    required this.difficulty,
    required this.completed,
    required this.accent,
    required this.rank,
    required this.onTap,
    required this.onPractice,
    required this.onLeaderboard,
  });

  @override
  State<_TierCard> createState() => _TierCardState();
}

class _TierCardState extends State<_TierCard> {
  bool _pressed = false;

  /// Compact trailing-action button (20px glyph, 36px hit area) so the practice
  /// + per-tier leaderboard icons leave the label room to render in full.
  Widget _cardIconButton({
    required Key iconKey,
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      key: iconKey,
      tooltip: tooltip,
      icon: Icon(icon, color: AppColors.textMuted),
      iconSize: 20,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        minimumSize: const Size(36, 36),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.difficulty;
    final completed = widget.completed;
    final accent = widget.accent;

    return AnimatedScale(
      scale: _pressed ? 0.97 : 1.0,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: InkWell(
          key: Key('tier-${d.name}'),
          borderRadius: BorderRadius.circular(AppRadii.md),
          onTap: widget.onTap,
          onHighlightChanged: (v) => setState(() => _pressed = v),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(
                color: completed
                    ? AppColors.success.withValues(alpha: 0.45)
                    : accent.withValues(alpha: 0.35),
                width: 1.5,
              ),
            ),
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: completed ? 0.3 : 1.0),
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                  ),
                  alignment: Alignment.center,
                  child: Text('${d.startingFill}',
                      style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // The label gets the full column width on its own line and
                      // a scale-down FittedBox so longer tiers (e.g. "Legendary")
                      // render in full — never ellipsized — even with the online
                      // per-tier leaderboard icon present. It keeps full size on
                      // real-device widths and only shrinks on very narrow ones.
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(d.label,
                              maxLines: 1,
                              softWrap: false,
                              style: TextStyle(
                                  color: completed
                                      ? AppColors.textMuted
                                      : AppColors.textPrimary,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800)),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      // Difficulty pips + status share the second line; the
                      // status can ellipsize (never the fixed trailing row), so
                      // the card never overflows on narrow phones.
                      Row(
                        children: [
                          _DifficultyPips(
                            filled: widget.rank + 1,
                            total: Difficulty.values.length,
                            color: accent,
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Text(
                              completed
                                  ? 'Done today ✓'
                                  : '${d.startingFill} starting tiles',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: completed
                                      ? AppColors.success
                                      : AppColors.textFaint,
                                  fontSize: 13,
                                  fontWeight: completed
                                      ? FontWeight.w700
                                      : FontWeight.w400),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                _cardIconButton(
                  iconKey: Key('practice-${d.name}'),
                  tooltip: 'Practice',
                  icon: Icons.fitness_center,
                  onPressed: widget.onPractice,
                ),
                if (widget.onLeaderboard != null)
                  _cardIconButton(
                    iconKey: Key('leaderboard-${d.name}'),
                    tooltip: 'Leaderboard',
                    icon: Icons.leaderboard,
                    onPressed: widget.onLeaderboard!,
                  ),
                Icon(
                  completed ? Icons.check_circle : Icons.chevron_right,
                  color: completed
                      ? AppColors.success
                      : AppColors.textMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact 1-of-N difficulty meter rendered as filled/empty dots.
class _DifficultyPips extends StatelessWidget {
  final int filled;
  final int total;
  final Color color;

  const _DifficultyPips({
    required this.filled,
    required this.total,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < total; i++)
          Padding(
            padding: const EdgeInsets.only(right: 3),
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < filled ? color : AppColors.border,
              ),
            ),
          ),
      ],
    );
  }
}
