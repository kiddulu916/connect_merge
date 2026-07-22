import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'application/duel_cubit.dart';
import 'application/account_flow_controller.dart';
import 'application/engagement_cubit.dart';
import 'application/game_cubit.dart' show utcToday;
import 'application/game_session_factory.dart';
import 'application/loot_cubit.dart';
import 'application/rivalry_cubit.dart';
import 'domain/models/duel_challenge.dart';
import 'domain/models/friend.dart';
import 'domain/models/player_level.dart';
import 'infrastructure/ad_service.dart';
import 'infrastructure/analytics_service.dart';
import 'infrastructure/consent_service.dart';
import 'infrastructure/auth_service.dart';
import 'infrastructure/crash_reporting_service.dart';
import 'infrastructure/deep_link_service.dart';
import 'infrastructure/friends_service.dart';
import 'infrastructure/hive_storage_service.dart';
import 'infrastructure/leaderboard_service.dart';
import 'infrastructure/notification_service.dart';
import 'infrastructure/profile_sync_service.dart';
import 'infrastructure/supabase_client.dart';
import 'presentation/screens/auth_gate_screen.dart';
import 'presentation/screens/display_name_screen.dart';
import 'presentation/screens/tier_select_screen.dart';

Future<void> main() async {
  CrashReportingService? crashReporting;
  AnalyticsService? analytics;

  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    try {
      await Firebase.initializeApp();
      crashReporting = CrashReportingService();
      analytics = AnalyticsService();
      FlutterError.onError = (details) {
        crashReporting?.recordError(details.exception, details.stack,
            fatal: true);
      };
      WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
        crashReporting?.recordError(error, stack, fatal: true);
        return true;
      };
    } catch (_) {
      // No Firebase config (missing google-services.json/GoogleService-
      // Info.plist, or a test/CI environment with no platform channels):
      // observability stays fully no-op, exactly like initSupabase() below
      // degrades to offline play when Supabase isn't configured.
    }

    AuthService? auth;
    await Hive.initFlutter();
    final storage = HiveStorageService(
      currentUserId: () => auth?.currentUserId,
    );
    await storage.init();

    final adService = AdService(analytics: analytics);
    await adService.init(ConsentService());

    // Notifications are LOCAL only ($0, no FCM). Init the plugin + timezone here
    // but request OS permission lazily (after the first completion), never at cold launch.
    tzdata.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation(tz.local.name));
    } catch (_) {
      // tz.local defaults to UTC if the device zone can't be resolved; safe.
    }
    final notifPlugin = FlutterLocalNotificationsPlugin();
    await notifPlugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
    final notifications = NotificationService.plugin(notifPlugin);

    // Degrades gracefully: if Supabase isn't configured (no --dart-define) or
    // anon sign-in fails, the game still runs offline.
    LeaderboardService? leaderboard;
    FriendsService? friends;
    ProfileSyncService? profileSync;
    bool needsDisplayName = false;
    bool showAuthGate = false;
    bool recoveryRequired = storage.ownerRecordCorrupt ||
        (storage.owner?.recoveryRequired ?? false);
    recoveryRequired =
        recoveryRequired || !(storage.owner?.restoreComplete ?? true);
    final superseded = ValueNotifier<bool>(false);
    if (await initSupabase()) {
      auth = AuthService(supabase);
      leaderboard = LeaderboardService(supabase);
      friends = FriendsService(supabase);
      try {
        await auth.ensureSignedIn();
        needsDisplayName = !(await auth.hasDisplayName());
      } catch (_) {
        final owner = storage.owner;
        final uid = auth.currentUserId;
        final mustReconcile = uid != null &&
            (owner?.recoveryRequired == true ||
                owner?.restoreComplete == false ||
                (owner != null && owner.uid != uid));
        if (!mustReconcile) {
          // Normal offline / auth failure keeps today's local-only behavior.
          auth = null;
          leaderboard = null;
          friends = null;
          profileSync = null;
        }
      }
      final activeAuth = auth;
      if (activeAuth != null) {
        profileSync = ProfileSyncService(
          client: supabase,
          storage: storage,
          currentUid: () => auth?.currentUserId,
          onSuperseded: () => superseded.value = true,
          onError: crashReporting?.recordError,
          onLog: crashReporting?.log,
        );
        try {
          final bootstrap = await profileSync.bootstrap(
            hasGoogleIdentity: activeAuth.hasGoogleIdentity,
          );
          crashReporting?.log('profile bootstrap: ${bootstrap.name}');
          final route = initialAccountRoute(
            bootstrap: bootstrap,
            needsDisplayName: needsDisplayName,
            hasGoogleIdentity: activeAuth.hasGoogleIdentity,
          );
          recoveryRequired = route == InitialAccountRoute.recovery;
          showAuthGate = route == InitialAccountRoute.authGate;
          if (route == InitialAccountRoute.displayName) {
            needsDisplayName = true;
          }
        } catch (error, stack) {
          // Once a session exists, an ownership reconciliation failure cannot
          // degrade into gameplay: local bytes may belong to a different uid.
          recoveryRequired = true;
          crashReporting?.recordError(error, stack);
          crashReporting?.log('profile bootstrap failed before reconciliation');
        }
      }
    }

    // Profile-backed cubits hydrate only after bootstrap has either restored
    // every live key or selected the normal/offline branch. Their load methods
    // are synchronous Hive reads, so this ordering is the awaited restore
    // barrier before TierSelectScreen can inspect tutorialSeen.
    final engagement = EngagementCubit(
      storage: storage,
      onError: crashReporting?.recordError,
      onAnalyticsEvent: analytics?.logEvent,
    )..load();
    final loot = LootCubit(storage: storage)..load();
    final rivalry = RivalryCubit(storage: storage)..load();
    final duels = DuelCubit(
      todayProvider: utcToday,
      onAnalyticsEvent: analytics?.logEvent,
    );

    final sessions = GameSessionFactory(
      storage: storage,
      engagement: engagement,
      loot: loot,
      leaderboard: leaderboard,
      onError: crashReporting?.recordError,
      onAnalyticsEvent: analytics?.logEvent,
    );

    // Deep links: invites (connectmerge://invite/<code>) AND duels
    // (connectmerge://duel/...). Duels need no backend (the challenge rides in the
    // link), so the service is started whenever EITHER is usable — i.e. always.
    // Captures cold-start links so a redeem/challenge isn't lost before the app is
    // ready; the app replays the pending code/duel once it's ready.
    final deepLinks = DeepLinkService();
    await deepLinks.init();

    runApp(ConnectMergeApp(
      storage: storage,
      adService: adService,
      auth: auth,
      leaderboard: leaderboard,
      friends: friends,
      deepLinks: deepLinks,
      engagement: engagement,
      loot: loot,
      sessions: sessions,
      rivalry: rivalry,
      duels: duels,
      notifications: notifications,
      needsDisplayName: needsDisplayName,
      showAuthGate: showAuthGate,
      recoveryRequired: recoveryRequired,
      profileSync: profileSync,
      superseded: superseded,
      crashReporting: crashReporting,
      analytics: analytics,
    ));
  }, (error, stack) {
    crashReporting?.recordError(error, stack, fatal: true);
  });
}

class ConnectMergeApp extends StatefulWidget {
  final HiveStorageService storage;
  final AdService adService;
  final AuthService? auth;
  final LeaderboardService? leaderboard;
  final FriendsService? friends;
  final DeepLinkService? deepLinks;
  final EngagementCubit engagement;
  final LootCubit loot;
  final GameSessionFactory sessions;
  final RivalryCubit? rivalry;
  final DuelCubit? duels;
  final NotificationService notifications;
  final bool needsDisplayName;
  final bool showAuthGate;
  final bool recoveryRequired;
  final ProfileSyncService? profileSync;
  final ValueNotifier<bool> superseded;
  final CrashReportingService? crashReporting;
  final AnalyticsService? analytics;

  const ConnectMergeApp({
    super.key,
    required this.storage,
    required this.adService,
    required this.engagement,
    required this.loot,
    required this.sessions,
    required this.notifications,
    this.auth,
    this.leaderboard,
    this.friends,
    this.deepLinks,
    this.rivalry,
    this.duels,
    this.needsDisplayName = false,
    this.showAuthGate = false,
    this.recoveryRequired = false,
    this.profileSync,
    required this.superseded,
    this.crashReporting,
    this.analytics,
  });

  @override
  State<ConnectMergeApp> createState() => _ConnectMergeAppState();
}

class _ConnectMergeAppState extends State<ConnectMergeApp>
    with WidgetsBindingObserver {
  late bool _needsDisplayName;
  late bool _showAuthGate;
  late bool _recoveryRequired;
  AccountFlowController? _accountFlow;
  final AccountWorkTracker _accountWork = AccountWorkTracker();
  bool _accountWorkStarted = false;
  bool _loadingAccount = false;
  bool _recoverFreshGuest = false;
  final _navKey = GlobalKey<NavigatorState>();
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    _needsDisplayName = widget.needsDisplayName;
    _showAuthGate = widget.showAuthGate;
    _recoveryRequired = widget.recoveryRequired;
    WidgetsBinding.instance.addObserver(this);
    widget.superseded.addListener(_onSuperseded);
    final auth = widget.auth;
    final sync = widget.profileSync;
    if (auth != null && sync != null) {
      _accountFlow = AccountFlowController(
        auth: auth,
        sync: sync,
        storage: widget.storage,
        drainAccountWork: _drainAccountWork,
        reloadLocalState: _reloadLocalState,
        onEvent: widget.analytics?.logEvent,
        onError: widget.crashReporting?.recordError,
      );
    }
    _wireDeepLinks();
    if (!_showAuthGate && !_needsDisplayName && !_recoveryRequired) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _startAccountWork());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.superseded.removeListener(_onSuperseded);
    widget.profileSync?.dispose();
    widget.loot.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(widget.profileSync?.flush());
    }
  }

  Future<void> _reloadLocalState() async {
    widget.engagement.load();
    widget.loot.load();
    widget.rivalry?.load();
  }

  void _startAccountWork() {
    final leaderboard = widget.leaderboard;
    if (_accountWorkStarted || leaderboard == null) return;
    _accountWorkStarted = true;
    _accountWork.retainAll([
      widget.engagement.checkDailyPrizes(leaderboard.myDailyRanks),
      widget.engagement.checkWeeklyPrizes(leaderboard.myPeriodRanks),
      widget.engagement.checkMonthlyPrizes(leaderboard.myPeriodRanks),
      widget.engagement.checkChallengePayouts(leaderboard.myDailyRanks),
    ]);
  }

  Future<void> _drainAccountWork() async {
    await _accountWork.drain();
    _accountWorkStarted = false;
  }

  /// Route invite codes + duels (cold-start queued or warm) to their handlers
  /// once the app is ready. Invites need the friends backend; duels do not (the
  /// challenge rides in the link), so duels are wired whenever a [DuelCubit] is
  /// present.
  void _wireDeepLinks() {
    final dl = widget.deepLinks;
    if (dl == null) return;

    // --- Invites (require the friends backend). ---
    final friends = widget.friends;
    if (friends != null) {
      dl.onInviteCode = _redeemInvite;
      // Replay a cold-start code captured before this handler was wired.
      final pending = dl.takePendingCode();
      if (pending != null) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _redeemInvite(pending));
      }
    }

    // --- Duels (no backend needed). ---
    final duels = widget.duels;
    if (duels != null) {
      dl.onDuel = _receiveDuel;
      // Replay a cold-start duel captured before this handler was wired.
      final pendingDuel = dl.takePendingDuel();
      if (pendingDuel != null) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _receiveDuel(pendingDuel));
      }
    }
  }

  /// Accept an incoming duel challenge: hand it to the [DuelCubit] and surface a
  /// prompt. The challenger's score is DISPLAY-ONLY — it never touches any
  /// leaderboard row (ranking stays with the verified leaderboard).
  void _receiveDuel(DuelChallenge duel) {
    final duels = widget.duels;
    if (duels == null) return;
    duels.receiveChallenge(duel);
    final message = duels.state.expired
        ? 'That duel board has expired — try today\'s '
            '${duel.difficulty.label} board.'
        : '${duel.challengerName} challenged you on '
            '${duel.difficulty.label}! Play the same board to settle it.';
    _messengerKey.currentState?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _redeemInvite(String code) async {
    final friends = widget.friends;
    if (friends == null) return;
    // Defer until onboarding is complete (signed in + display name set).
    if (_needsDisplayName || _showAuthGate || _recoveryRequired) {
      widget.deepLinks?.onInviteCode = null;
      widget.deepLinks?.takePendingCode();
      // Re-queue: store on the service-less side by re-arming after onboarding.
      _pendingAfterOnboarding = code;
      return;
    }
    String message;
    try {
      final res = await friends.redeemCode(code);
      message = switch (res.status) {
        RedeemStatus.ok => 'Friend added!',
        RedeemStatus.self => "That's your own invite link.",
        RedeemStatus.invalidCode => 'That invite link is invalid.',
        RedeemStatus.unauthenticated => 'Sign in required to add friends.',
        RedeemStatus.error => 'Could not add friend. Try again.',
      };
    } catch (_) {
      message = 'Network error adding friend.';
    }
    _messengerKey.currentState?.showSnackBar(SnackBar(content: Text(message)));
  }

  String? _pendingAfterOnboarding;

  Future<void> _showReady() async {
    if (!mounted) return;
    setState(() {
      _needsDisplayName = false;
      _showAuthGate = false;
      _recoveryRequired = false;
      _loadingAccount = false;
    });
    final dl = widget.deepLinks;
    if (dl != null && widget.friends != null) {
      dl.onInviteCode = _redeemInvite;
    }
    final pending = _pendingAfterOnboarding;
    _pendingAfterOnboarding = null;
    if (pending != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _redeemInvite(pending));
    }
    _startAccountWork();
  }

  Future<void> _onDisplayNameSaved() async {
    await _accountFlow!.completeDisplayName();
    await _showReady();
  }

  Future<bool> _playAsGuest() async {
    await _accountFlow!.playAsGuest();
    await _showReady();
    return true;
  }

  Future<bool> _continueWithGoogle({required bool hasDisplayName}) async {
    final flow = _accountFlow!;
    final outcome = await flow.beginGoogle(hasDisplayName: hasDisplayName);
    switch (outcome) {
      case GoogleFlowOutcome.linkedNeedsDisplayName:
        setState(() {
          _showAuthGate = false;
          _needsDisplayName = true;
        });
        return true;
      case GoogleFlowOutcome.linkedReady:
        await _showReady();
        return true;
      case GoogleFlowOutcome.collision:
        return _showCollisionWarning();
      case GoogleFlowOutcome.blockedRecovery:
        setState(() => _recoveryRequired = true);
        return true;
      case GoogleFlowOutcome.adoptedNeedsDisplayName ||
            GoogleFlowOutcome.adoptedReady:
        throw StateError('Unexpected pre-adoption outcome.');
    }
  }

  Future<bool> _showCollisionWarning() async {
    final context = _navKey.currentContext;
    if (context == null) return false;
    final profile = widget.storage.loadProfile();
    final level = levelForXp(profile.progression.lifetimeXp);
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Switch profiles?'),
        content: Text(
          'This Google account already has a Connect Merge profile. '
          'Signing in switches to it and permanently abandons this device\'s '
          'guest account — level $level, ${profile.wallet.coins} coins, a '
          '${profile.activity.dailyActiveStreak}-day streak, and its '
          'leaderboard scores and friends.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-google-adopt'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Switch profile'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      _accountFlow!.cancelAdopt();
      return false;
    }
    setState(() => _loadingAccount = true);
    late final GoogleFlowOutcome outcome;
    try {
      outcome = await _accountFlow!.confirmAdopt();
    } catch (error, stack) {
      widget.crashReporting?.recordError(error, stack);
      final uid = widget.auth?.currentUserId;
      final ownerUid = widget.storage.owner?.uid;
      if (mounted) {
        setState(() {
          _loadingAccount = false;
          _recoveryRequired = uid != null && uid != ownerUid;
        });
        if (_recoveryRequired) {
          _navKey.currentState?.popUntil((route) => route.isFirst);
        }
      }
      rethrow;
    }
    if (!mounted) return true;
    switch (outcome) {
      case GoogleFlowOutcome.adoptedReady:
        await _showReady();
        return true;
      case GoogleFlowOutcome.adoptedNeedsDisplayName:
        setState(() {
          _loadingAccount = false;
          _showAuthGate = false;
          _needsDisplayName = true;
        });
        return true;
      case GoogleFlowOutcome.blockedRecovery:
        setState(() {
          _loadingAccount = false;
          _recoveryRequired = true;
        });
        return true;
      case GoogleFlowOutcome.linkedNeedsDisplayName ||
            GoogleFlowOutcome.linkedReady ||
            GoogleFlowOutcome.collision:
        throw StateError('Unexpected post-adoption outcome.');
    }
  }

  Future<bool> _confirmUnsyncedExit() async {
    if (await _accountFlow!.canExitWithoutDataLoss()) return true;
    final context = _navKey.currentContext;
    if (context == null || !context.mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Unsaved progress'),
            content: const Text(
              'Your latest progress could not be saved. Signing out now will '
              'permanently lose those changes.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Stay signed in'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Sign out anyway'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<bool> _signOut() async {
    if (!await _confirmUnsyncedExit()) return false;
    // The first flush covers foreground writes; prize futures can still land
    // while being drained, so flush once more after that provenance barrier.
    // This second guarded push is what makes "final" include every retained
    // account-scoped write rather than only the state visible at button tap.
    await _drainAccountWork();
    if (!await _confirmUnsyncedExit()) return false;
    setState(() => _loadingAccount = true);
    try {
      await _accountFlow!.signOut();
    } catch (error, stack) {
      widget.crashReporting?.recordError(error, stack);
      if (!mounted) rethrow;
      final uid = widget.auth?.currentUserId;
      if (uid == null || uid != widget.storage.owner?.uid) {
        setState(() {
          _loadingAccount = false;
          _recoveryRequired = true;
          _recoverFreshGuest = true;
        });
        return true;
      }
      setState(() => _loadingAccount = false);
      rethrow;
    }
    if (!mounted) return true;
    setState(() {
      _loadingAccount = false;
      _showAuthGate = true;
      _needsDisplayName = true;
      _recoveryRequired = false;
    });
    return true;
  }

  Future<void> _deleteAccount() async {
    setState(() => _loadingAccount = true);
    try {
      await _accountFlow!.deleteAccount();
    } catch (error, stack) {
      widget.crashReporting?.recordError(error, stack);
      if (!mounted) rethrow;
      final uid = widget.auth?.currentUserId;
      if (uid == null || uid != widget.storage.owner?.uid) {
        setState(() {
          _loadingAccount = false;
          _recoveryRequired = true;
          _recoverFreshGuest = true;
        });
        return;
      }
      setState(() => _loadingAccount = false);
      rethrow;
    }
    if (!mounted) return;
    setState(() {
      _loadingAccount = false;
      _showAuthGate = true;
      _needsDisplayName = true;
      _recoveryRequired = false;
    });
  }

  void _changeName() {
    final context = _navKey.currentContext;
    final auth = widget.auth;
    if (context == null || auth == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DisplayNameScreen(
          auth: auth,
          analytics: widget.analytics,
          onSaved: () async {
            _navKey.currentState?.pop();
          },
        ),
      ),
    );
  }

  void _onSuperseded() {
    if (!widget.superseded.value || !mounted) return;
    widget.superseded.value = false;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final context = _navKey.currentContext;
      if (!mounted || context == null) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Profile opened elsewhere'),
          content: const Text(
            'Your profile was opened on another device. Progress on this '
            'device isn\'t being saved.',
          ),
          actions: [
            FilledButton(
              key: const Key('reload-cloud-profile'),
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                setState(() => _loadingAccount = true);
                try {
                  await _accountFlow!.reloadProfile();
                  await _showReady();
                } catch (_) {
                  if (mounted) {
                    setState(() {
                      _loadingAccount = false;
                      _recoveryRequired = true;
                    });
                  }
                }
              },
              child: const Text('Reload profile'),
            ),
          ],
        ),
      );
    });
  }

  Future<void> _retryRecovery() async {
    setState(() => _loadingAccount = true);
    try {
      if (_recoverFreshGuest) {
        await _accountFlow!.recoverFreshGuest();
        if (!mounted) return;
        setState(() {
          _loadingAccount = false;
          _recoveryRequired = false;
          _recoverFreshGuest = false;
          _needsDisplayName = true;
          _showAuthGate = true;
        });
        return;
      }
      await _accountFlow!.reloadProfile();
      await _showReady();
    } catch (_) {
      if (mounted) setState(() => _loadingAccount = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget home;
    if (_loadingAccount) {
      home = const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    } else if (_recoveryRequired) {
      home = Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Your cloud profile could not be restored safely.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'No local progress has been uploaded. Try again when '
                    'online, or contact support if this continues.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _accountFlow == null ? null : _retryRecovery,
                    child: const Text('Retry restore'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } else if (_showAuthGate && _accountFlow != null) {
      home = AuthGateScreen(
        onGoogle: () => _continueWithGoogle(hasDisplayName: false),
        onGuest: _playAsGuest,
      );
    } else if (_needsDisplayName && widget.auth != null) {
      home = DisplayNameScreen(
        auth: widget.auth!,
        analytics: widget.analytics,
        onSaved: _onDisplayNameSaved,
      );
    } else {
      home = TierSelectScreen(
        storage: widget.storage,
        adService: widget.adService,
        leaderboard: widget.leaderboard,
        friends: widget.friends,
        auth: widget.auth,
        onAccountDeleted: _accountFlow == null ? null : _deleteAccount,
        onSignOut: _accountFlow == null ? null : _signOut,
        onSaveProgress: _accountFlow == null
            ? null
            : () => _continueWithGoogle(hasDisplayName: true),
        onChangeName: _accountFlow == null ? null : _changeName,
        engagement: widget.engagement,
        loot: widget.loot,
        sessions: widget.sessions,
        rivalry: widget.rivalry,
        duels: widget.duels,
        notifications: widget.notifications,
        crashReporting: widget.crashReporting,
        analytics: widget.analytics,
      );
    }
    return MaterialApp(
      title: 'Connect Merge',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navKey,
      scaffoldMessengerKey: _messengerKey,
      theme: ThemeData.dark(useMaterial3: true),
      navigatorObservers: [
        if (widget.analytics != null) widget.analytics!.navigatorObserver,
      ],
      home: home,
    );
  }
}
