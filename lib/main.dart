import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'application/duel_cubit.dart';
import 'application/engagement_cubit.dart';
import 'application/game_cubit.dart' show utcToday;
import 'application/rivalry_cubit.dart';
import 'domain/models/duel_challenge.dart';
import 'domain/models/friend.dart';
import 'infrastructure/ad_service.dart';
import 'infrastructure/auth_service.dart';
import 'infrastructure/deep_link_service.dart';
import 'infrastructure/friends_service.dart';
import 'infrastructure/hive_storage_service.dart';
import 'infrastructure/leaderboard_service.dart';
import 'infrastructure/notification_service.dart';
import 'infrastructure/supabase_client.dart';
import 'presentation/screens/display_name_screen.dart';
import 'presentation/screens/tier_select_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter();
  final storage = HiveStorageService();
  await storage.init();

  final adService = AdService();
  await adService.init();

  // Phase 4 retention layer. Notifications are LOCAL only (\$0, no FCM). We init
  // the plugin + timezone here but request OS permission lazily (after the first
  // completion), never at cold launch.
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

  final engagement = EngagementCubit(storage: storage)..load();

  // Phase 3 social layer. Both are profile-backed + offline-safe: the rival
  // relationship persists locally and duels carry their payload in the link, so
  // neither needs a backend ($0). Hydrate the rival from storage now.
  final rivalry = RivalryCubit(storage: storage)..load();
  final duels = DuelCubit(todayProvider: utcToday);

  // Online layer (Phase 2). Degrades gracefully: if Supabase isn't configured
  // (no --dart-define) or anon sign-in fails, the game still runs offline.
  AuthService? auth;
  LeaderboardService? leaderboard;
  FriendsService? friends;
  bool needsDisplayName = false;
  if (await initSupabase()) {
    auth = AuthService(supabase);
    leaderboard = LeaderboardService(supabase);
    friends = FriendsService(supabase);
    try {
      await auth.ensureSignedIn();
      needsDisplayName = !(await auth.hasDisplayName());
    } catch (_) {
      // Offline / auth failure: keep playing offline; retry on next launch.
      auth = null;
      leaderboard = null;
      friends = null;
    }
  }

  // Deep links: invites (mergecount://invite/<code>) AND duels
  // (mergecount://duel/...). Duels need no backend (the challenge rides in the
  // link), so the service is started whenever EITHER is usable — i.e. always.
  // Captures cold-start links so a redeem/challenge isn't lost before the app is
  // ready; the app replays the pending code/duel once it's ready.
  final deepLinks = DeepLinkService();
  await deepLinks.init();

  runApp(MergeCountApp(
    storage: storage,
    adService: adService,
    auth: auth,
    leaderboard: leaderboard,
    friends: friends,
    deepLinks: deepLinks,
    engagement: engagement,
    rivalry: rivalry,
    duels: duels,
    notifications: notifications,
    needsDisplayName: needsDisplayName,
  ));
}

class MergeCountApp extends StatefulWidget {
  final HiveStorageService storage;
  final AdService adService;
  final AuthService? auth;
  final LeaderboardService? leaderboard;
  final FriendsService? friends;
  final DeepLinkService? deepLinks;
  final EngagementCubit engagement;
  final RivalryCubit? rivalry;
  final DuelCubit? duels;
  final NotificationService notifications;
  final bool needsDisplayName;

  const MergeCountApp({
    super.key,
    required this.storage,
    required this.adService,
    required this.engagement,
    required this.notifications,
    this.auth,
    this.leaderboard,
    this.friends,
    this.deepLinks,
    this.rivalry,
    this.duels,
    this.needsDisplayName = false,
  });

  @override
  State<MergeCountApp> createState() => _MergeCountAppState();
}

class _MergeCountAppState extends State<MergeCountApp> {
  late bool _needsDisplayName;
  final _navKey = GlobalKey<NavigatorState>();
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    _needsDisplayName = widget.needsDisplayName;
    _wireDeepLinks();
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
    if (_needsDisplayName) {
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

  void _onOnboarded() {
    setState(() => _needsDisplayName = false);
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
  }

  @override
  Widget build(BuildContext context) {
    final Widget home;
    if (_needsDisplayName && widget.auth != null) {
      home = DisplayNameScreen(
        auth: widget.auth!,
        onSaved: _onOnboarded,
      );
    } else {
      home = TierSelectScreen(
        storage: widget.storage,
        adService: widget.adService,
        leaderboard: widget.leaderboard,
        friends: widget.friends,
        engagement: widget.engagement,
        rivalry: widget.rivalry,
        duels: widget.duels,
        notifications: widget.notifications,
      );
    }
    return MaterialApp(
      title: 'Merge Count',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navKey,
      scaffoldMessengerKey: _messengerKey,
      theme: ThemeData.dark(useMaterial3: true),
      home: home,
    );
  }
}
