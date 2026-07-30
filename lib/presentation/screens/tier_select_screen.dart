import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../application/duel_cubit.dart';
import '../../application/engagement_cubit.dart';
import '../../application/game_cubit.dart' show utcToday;
import '../../application/game_session_factory.dart';
import '../../application/loot_cubit.dart';
import '../../application/rivalry_cubit.dart';
import '../../domain/engine/daily_seeder.dart';
import '../../domain/models/challenge_rule.dart';
import '../../domain/models/difficulty.dart';
import '../../domain/models/duel_challenge.dart';
import '../../infrastructure/ad_service.dart';
import '../../infrastructure/analytics_service.dart';
import '../../infrastructure/auth_service.dart';
import '../../infrastructure/crash_reporting_service.dart';
import '../../infrastructure/friends_service.dart';
import '../../infrastructure/leaderboard_service.dart';
import '../../infrastructure/notification_service.dart';
import '../../infrastructure/storage_service.dart';
import '../theme/tile_palette.dart';
import '../theme/tokens.dart';
import '../widgets/duel_banner.dart';
import '../widgets/rival_indicator.dart';
import 'achievements_screen.dart';
import 'almanac_screen.dart';
import 'cosmetics_screen.dart';
import 'friends_screen.dart';
import 'game_screen.dart';
import 'leaderboard_screen.dart';
import 'loot_chest_screen.dart';
import 'practice_screen.dart';
import 'profile_screen.dart';
import 'tier_select/challenge_card.dart';
import 'tier_select/loot_leaderboard_row.dart';
import 'tier_select/streak_section.dart';
import 'tier_select/tier_card.dart';
import 'tier_select/tier_select_app_bar.dart';
import 'tier_select/tier_tour_mixin.dart';

/// Entry screen: pick a difficulty tier. Each card shows the starting tile
/// count, whether the tier is already done today, and a live countdown to the
/// 00:00 UTC reset.
class TierSelectScreen extends StatefulWidget {
  final StorageService storage;
  final AdService adService;

  /// Online leaderboard service. Null when offline / Supabase not configured —
  /// the leaderboard entry points are then hidden.
  final LeaderboardService? leaderboard;

  /// Production game-session composition. Nullable only so tests that use
  /// [onTierSelected] can keep lightweight screen construction.
  final GameSessionFactory? sessions;

  /// Friends service. Null when offline — the Friends entry point and the
  /// Global/Friends toggle are then hidden.
  final FriendsService? friends;

  /// Auth service. Null when offline — the Profile entry point (Player ID +
  /// delete-my-data) is then hidden.
  final AuthService? auth;

  /// Called after the player deletes their account in the Profile screen (all
  /// routes already popped). The app shell re-onboards.
  final Future<void> Function()? onAccountDeleted;
  final Future<bool> Function()? onSignOut;
  final Future<bool> Function()? onSaveProgress;
  final VoidCallback? onChangeName;

  /// Phase 4 retention orchestration (streaks, achievements, cosmetics). When
  /// null (tests), a local cubit is created from [storage].
  final EngagementCubit? engagement;

  /// Observability services (both optional — null when Firebase isn't
  /// configured, or in tests). Threaded to the locally-created
  /// `EngagementCubit` fallback; production game sessions receive them from
  /// [sessions].
  final CrashReportingService? crashReporting;
  final AnalyticsService? analytics;

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
    this.sessions,
    this.friends,
    this.auth,
    this.onAccountDeleted,
    this.onSignOut,
    this.onSaveProgress,
    this.onChangeName,
    this.engagement,
    this.loot,
    this.rivalry,
    this.duels,
    this.notifications,
    this.todayProvider,
    this.onTierSelected,
    this.crashReporting,
    this.analytics,
  });

  String today() => (todayProvider ?? utcToday)();

  @override
  State<TierSelectScreen> createState() => _TierSelectScreenState();
}

class _TierSelectScreenState extends State<TierSelectScreen>
    with TierTourMixin {
  Timer? _ticker;
  Duration _untilReset = Duration.zero;
  final _tourScrollController = ScrollController();
  final _tierListKey = GlobalKey(debugLabel: 'tutorial-tier-list');
  final _practiceTourKeys = <Difficulty, GlobalKey>{
    for (final difficulty in Difficulty.values
        .where((difficulty) => difficulty != Difficulty.challenge))
      difficulty: GlobalKey(debugLabel: 'tutorial-practice-${difficulty.name}'),
  };

  @override
  GlobalKey get tierListKey => _tierListKey;

  @override
  Map<Difficulty, GlobalKey> get practiceTourKeys => _practiceTourKeys;

  @override
  EngagementCubit get engagementCubit => _engagement;

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
            storage: widget.storage,
            todayProvider: widget.todayProvider,
            onError: widget.crashReporting?.recordError,
            onAnalyticsEvent: widget.analytics?.logEvent)
          ..load());
    _ownsEngagement = widget.engagement == null;
    _loot = widget.loot ??
        (LootCubit(storage: widget.storage, todayProvider: widget.todayProvider)
          ..load());
    _ownsLoot = widget.loot == null;
    _rivalry =
        widget.rivalry ?? (RivalryCubit(storage: widget.storage)..load());
    _ownsRivalry = widget.rivalry == null;
    _untilReset = _computeUntilReset();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _untilReset = _computeUntilReset());
    });
    _loadFriendCode();
    // On app-open: reschedule the daily reminder based on current state, and
    // check whether a chosen rival has overtaken us (fires the nudge + refreshes
    // the you-vs-rival chip).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rescheduleNotifications();
      _checkRivalOvertake();
    });
    if (!widget.storage.loadProfile().settings.tutorialSeen) {
      tourPhase = TourPhase.mechanics;
      widget.analytics?.logEvent('tutorial_started');
      WidgetsBinding.instance.addPostFrameCallback((_) => launchMechanics());
    }
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
    _tourScrollController.dispose();
    if (_ownsEngagement) _engagement.close();
    if (_ownsLoot) _loot.close();
    if (_ownsRivalry) _rivalry.close();
    super.dispose();
  }

  /// True when every tier's day is already completed.
  bool _allTiersDoneToday() => Difficulty.values
      .where((d) => d != Difficulty.challenge)
      .every(_isCompleted);

  /// Reschedule the daily reminder + streak-expiry warning. No-op without a
  /// notification service or when permission isn't granted yet (the plan is
  /// still computed but the plugin gracefully ignores undelivered schedules).
  Future<void> _rescheduleNotifications() async {
    final notif = widget.notifications;
    if (notif == null) return;
    final profile = widget.storage.loadProfile();
    final streak = profile.activity.dailyActiveStreak;
    final today = widget.today();
    // Streak is at risk if there's an active streak that hasn't advanced today.
    final atRisk = streak > 0 && profile.activity.lastActiveDate != today;
    try {
      await notif.reschedule(
        now: tz.TZDateTime.now(tz.local),
        reminderMinutes: profile.settings.reminderMinutes,
        enabled: profile.settings.notificationsEnabled,
        allTiersDoneToday: _allTiersDoneToday(),
        streakAtRisk: atRisk,
        lootUnclaimed: profile.wallet.lastLootClaimDate != today,
      );
    } catch (_) {
      // Notifications are best-effort; never block the UI.
    }
  }

  /// On app-open: if a rival is set and a friends fetch is available, pull the
  /// rival's score on the first still-incomplete tier and route it through
  /// [RivalryCubit.recordRivalScore], which fires the "your rival passed you"
  /// nudge at most once per overtake and refreshes the you-vs-rival chip.
  ///
  /// Best-effort: no rival, no friends service, offline, or a rival who hasn't
  /// played the tier today all silently skip. `recordRivalScore` keeps its own
  /// monotonic last-seen, so a stale/lower fetch can't re-arm an old overtake.
  ///
  /// ponytail: app-open detection only — there's no background fetch, so the OS
  /// nudge can surface right after the user has already opened the app. Upgrade
  /// path: move behind a background worker if re-engagement lift justifies it.
  Future<void> _checkRivalOvertake() async {
    final friends = widget.friends;
    final rivalId = _rivalry.state.rivalId;
    final rivalName = _rivalry.state.rivalName;
    if (friends == null || rivalId == null || rivalName == null) return;
    // The same tier the you-vs-rival chip shows: first still-incomplete tier.
    final tier = Difficulty.values.firstWhere(
      (d) => !_isCompleted(d),
      orElse: () => Difficulty.values.first,
    );
    try {
      final rows =
          await friends.friendsLeaderboard(difficulty: tier, date: widget.today());
      final rivalRows = rows.where((e) => e.playerId == rivalId);
      if (rivalRows.isEmpty) return; // Rival hasn't played this tier today.
      final rivalScore = rivalRows.first.score;
      final myScore = widget.storage.scoreFor(widget.today(), tier) ?? 0;
      final passed = await _rivalry.recordRivalScore(
        difficulty: tier,
        myScore: myScore,
        rivalScore: rivalScore,
      );
      final notif = widget.notifications;
      if (passed && notif != null) {
        await notif.showRivalPassed(
          now: tz.TZDateTime.now(tz.local),
          rivalName: rivalName,
          difficultyLabel: tier.label,
          rivalScore: rivalScore,
        );
      }
    } catch (_) {
      // Best-effort: never block the home screen on a rival fetch.
    }
  }

  Duration _computeUntilReset() {
    final now = DateTime.now().toUtc();
    final nextMidnight =
        DateTime.utc(now.year, now.month, now.day).add(const Duration(days: 1));
    return nextMidnight.difference(now);
  }

  /// True once the clock passes 12:00 UTC — the challenge unlocks at noon.
  bool get _challengeUnlocked => DateTime.now().toUtc().hour >= 12;

  /// Time remaining until the challenge unlocks. Only meaningful/shown by
  /// [ChallengeCard] when [_challengeUnlocked] is false.
  Duration _timeUntilChallengeUnlock() {
    final now = DateTime.now().toUtc();
    final noon = DateTime.utc(now.year, now.month, now.day, 12);
    return noon.difference(now);
  }

  /// Today's challenge rule label, derived deterministically from the date.
  String get _challengeRuleLabel =>
      DailySeeder(widget.today(), Difficulty.challenge).challengeRule.label;

  bool _isCompleted(Difficulty d) {
    final today = widget.today();
    return widget.storage.isCompletedFor(today, d);
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
        const SnackBar(
            content: Text('Leaderboards need an internet connection.')),
      );
      return;
    }
    _openLeaderboard(context, Difficulty.values.first);
  }

  void _openProfile(BuildContext context) {
    final auth = widget.auth;
    if (auth == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProfileScreen(
          auth: auth,
          storage: widget.storage,
          engagement: _engagement,
          onDelete: widget.onAccountDeleted,
          onSignOut: widget.onSignOut,
          onSaveProgress: widget.onSaveProgress,
          onChangeName: widget.onChangeName,
        ),
      ),
    );
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
          create: (_) => widget.sessions!.create(
            difficulty: difficulty,
            afterCompleted: _maybeRequestPermissionThenReschedule,
          ),
          child: GameScreen(
            adService: widget.adService,
            storage: widget.storage,
            engagement: _engagement,
            notifications: widget.notifications,
            friendCode: _friendCode,
            ensureFriendCode: widget.friends?.myFriendCode,
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
    final score = widget.storage.scoreFor(today, difficulty);
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

  /// Request notification permission CONTEXTUALLY (after the first completion),
  /// then (re)schedule. Only prompts once: marks notifications enabled in the
  /// profile when granted.
  Future<void> _maybeRequestPermissionThenReschedule() async {
    final notif = widget.notifications;
    if (notif == null) return;
    var profile = widget.storage.loadProfile();
    if (!profile.settings.notificationsEnabled) {
      bool granted = false;
      try {
        granted = await notif.requestPermission();
      } catch (_) {
        granted = false;
      }
      if (granted) {
        profile = profile.copyWith(
          settings: profile.settings.copyWith(notificationsEnabled: true),
        );
        await widget.storage.saveProfile(profile);
      }
    }
    await _rescheduleNotifications();
  }

  void _openAchievements(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            AchievementsScreen(unlocked: _engagement.state.unlocked),
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
      adType: 'streak_freeze',
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
    final content = SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top app bar: title left, secondary-nav icons right.
            TierSelectAppBar(
              showFriends: widget.friends != null,
              showProfile: widget.auth != null,
              onAchievements: () => _openAchievements(context),
              onCosmetics: () => _openCosmetics(context),
              onAlmanac: () => _openAlmanac(context),
              onFriends: () => _openFriends(context),
              onProfile: () => _openProfile(context),
            ),
            const SizedBox(height: AppSpacing.sm),
            StreakSection(
              engagement: _engagement,
              adBusy: widget.adService.showing,
              onFreezePressed: _watchFreezeAd,
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
                final mine = widget.storage.scoreFor(widget.today(), tier) ?? 0;
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
                      style:
                          TextStyle(color: AppColors.textMuted, fontSize: 14)),
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
                        Text('Resets in ${formatCountdown(_untilReset)}',
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
            LootLeaderboardRow(
              loot: _loot,
              onOpenLootChest: () => _openLootChest(context),
              onOpenLeaderboard: () => _openLeaderboardOrExplain(context),
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
                      onPlay: () => _startTier(context, challenge.difficulty),
                      onPlayToday: () =>
                          _startTier(context, challenge.difficulty),
                      onDismiss: () => widget.duels!.dismiss(),
                    ),
                  );
                },
              ),
            Expanded(
              child: KeyedSubtree(
                key: _tierListKey,
                child: ListView(
                  controller: _tourScrollController,
                  children: [
                    for (final d in Difficulty.values
                        .where((d) => d != Difficulty.challenge))
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                        child: TierCard(
                          difficulty: d,
                          completed: _isCompleted(d),
                          accent: TilePalette.colorForTier(d.startingFill),
                          rank: Difficulty.values.indexOf(d),
                          practiceTargetKey: _practiceTourKeys[d],
                          onTap: _isCompleted(d)
                              ? null
                              : () => _startTier(context, d),
                          onPractice: () => _openPractice(context, d),
                          onLeaderboard: widget.leaderboard == null
                              ? null
                              : () => _openLeaderboard(context, d),
                        ),
                      ),
                    ChallengeCard(
                      unlocked: _challengeUnlocked,
                      completed: _isCompleted(Difficulty.challenge),
                      ruleName: _challengeRuleLabel,
                      timeUntilUnlock: _timeUntilChallengeUnlock(),
                      onPlay: () => _startTier(context, Difficulty.challenge),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return PopScope(
      canPop: !tourActive,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && tourPhase != TourPhase.mechanics) {
          completeTour(
            skipped: true,
            step: tourPhase == TourPhase.tiers ? 6 : 7,
          );
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Stack(
          children: [
            Positioned.fill(
              child: AbsorbPointer(
                absorbing: tourActive,
                child: ExcludeSemantics(
                  excluding: tourActive,
                  child: content,
                ),
              ),
            ),
            if (tourPhase == TourPhase.tiers ||
                (tourPhase == TourPhase.leaderboard &&
                    (widget.leaderboard == null ||
                        completing ||
                        completionFailed)))
              Positioned.fill(child: buildTourOverlay()),
          ],
        ),
      ),
    );
  }
}
