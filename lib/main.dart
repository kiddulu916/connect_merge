import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'application/engagement_cubit.dart';
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
  await notifPlugin.initialize(const InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    ),
  ));
  final notifications = NotificationService.plugin(notifPlugin);

  final engagement = EngagementCubit(storage: storage)..load();

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

  // Deep links (mergeloop://invite/<code>). Captures cold-start links so a
  // redeem isn't lost before the app is ready; the app replays the pending code
  // once a signed-in session + display name exist (Phase 3 failure-mode).
  DeepLinkService? deepLinks;
  if (friends != null) {
    deepLinks = DeepLinkService();
    await deepLinks.init();
  }

  runApp(MergeCountApp(
    storage: storage,
    adService: adService,
    auth: auth,
    leaderboard: leaderboard,
    friends: friends,
    deepLinks: deepLinks,
    engagement: engagement,
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

  /// Route invite codes (cold-start queued or warm) to the redeem flow once the
  /// app is ready (signed in + named).
  void _wireDeepLinks() {
    final dl = widget.deepLinks;
    final friends = widget.friends;
    if (dl == null || friends == null) return;
    dl.onInviteCode = _redeemInvite;
    // Replay a cold-start code captured before this handler was wired.
    final pending = dl.takePendingCode();
    if (pending != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _redeemInvite(pending));
    }
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
