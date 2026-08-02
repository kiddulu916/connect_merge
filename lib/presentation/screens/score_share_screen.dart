import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../domain/models/achievement.dart';
import '../../domain/models/board_state.dart';
import '../../domain/models/cosmetic.dart';
import '../../domain/models/difficulty.dart';
import '../../domain/models/duel_challenge.dart';
import '../../infrastructure/friends_service.dart';
import '../../infrastructure/score_sharer.dart';
import '../../infrastructure/share_card_renderer.dart';
import '../../infrastructure/storage_service.dart';
import '../theme/tokens.dart';
import '../widgets/level_badge.dart';
import '../widgets/ad_busy_gate.dart';
import '../widgets/share_card.dart';

/// Offline daily result: the player's own score/tier/moves plus local personal
/// stats. The emoji share is the (offline) comparison mechanism. When a friend
/// code is available, the share card carries an invite link and a dedicated
/// "invite a friend" CTA is shown (Phase 3 growth lever).
class ScoreShareScreen extends StatefulWidget {
  final BoardState board;
  final String date;
  final LifetimeStats stats;
  final bool canOfferAd;
  final VoidCallback onWatchAd;
  final ValueListenable<bool> adBusy;

  /// Returns to the main menu (tier select). When null, no button is shown.
  final VoidCallback? onMainMenu;

  /// The player's friend code, when online. When present, the share text
  /// includes an invite link and an "Invite a friend" CTA is shown.
  final String? friendCode;

  /// Ensures a current friend code at share time. The eager [friendCode] remains
  /// a fast initial value, but this loader closes the game-start race.
  final Future<String> Function()? ensureFriendCode;

  /// Achievements unlocked by THIS run (Phase 4). Celebrated once here.
  final Set<Achievement> newlyUnlocked;

  /// Optional near-miss "so close" line (Phase 1), shown on a finished board
  /// that was one merge / a few points short. Null when none applies.
  final String? nearMiss;

  /// XP earned by THIS run (Phase 2). When > 0 an "+XP" line is shown.
  final int xpGained;

  /// The player's CURRENT level after this run (Phase 2). Shown as flair.
  final int level;

  /// Whether this run pushed the player up a level (Phase 2). Fires a one-shot
  /// level-up celebration banner when true.
  final bool leveledUp;

  /// Coins earned this run that can be doubled by a rewarded ad (Phase 2). When
  /// > 0 and [onDoubleCoins] is set, a "double coins" button is shown.
  final int coinsEarned;

  /// Whether the double-coins reward has already been taken (hides the button).
  final bool coinsDoubled;

  /// Rewarded-ad "double coins" handler (Phase 2). Null hides the button.
  final VoidCallback? onDoubleCoins;

  /// Observable total coins won this run (doubled-aware). When provided, a live
  /// coins summary is shown and the double-coins button hides reactively once
  /// the reward is taken — so the reward survives the fullscreen-ad round-trip
  /// instead of relying on this screen's (ephemeral) setState.
  final ValueListenable<int>? coinsWon;

  /// Seam: text-only native share, used by the [_invite] / [_challenge] flows.
  /// Production falls through to [_nativeShare]; tests inject a fake.
  final Future<void> Function(String text)? shareText;

  /// Performs the actual score share. Production uses [PlatformScoreSharer];
  /// tests inject a fake.
  final ScoreSharer sharer;

  /// Test seam: returns the PNG bytes to share, bypassing real rendering.
  /// Production leaves this null and captures the on-screen card.
  final Future<Uint8List?> Function()? captureOverride;

  /// Renderer seam for the richer [ShareCard] (Phase 3). Production captures the
  /// on-screen RepaintBoundary; tests inject [FakeShareCardRenderer]. When
  /// [captureOverride] is set it wins (kept for back-compat).
  final ShareCardRenderer renderer;

  /// This run's tier (Phase 3) — powers the rendered card + a duel challenge
  /// link. Defaults to easy for legacy callers that don't pass it.
  final Difficulty difficulty;

  /// Selected tile theme for the rendered card.
  final Cosmetic cosmetic;

  /// The player's display name (Phase 3), shown on the rendered card and used as
  /// the challenger name in a duel link. Null hides the name + duel CTA.
  final String? displayName;

  /// Best (lowest) leaderboard rank to flex on the card. Null/<=0 hides it.
  final int? rank;

  /// Set this run's opponent (the player themselves) as a duel target a friend
  /// can accept (Phase 3). When non-null, a "Challenge a friend" CTA is shown.
  /// Receives the encoded duel link to share.
  final Future<void> Function(String link)? onChallengeFriend;

  /// Mark the player as a rival of someone (Phase 3). When non-null, a "Set as
  /// rival" CTA is shown. (The actual rival selection happens on Friends.)
  final VoidCallback? onSetRival;

  const ScoreShareScreen({
    super.key,
    required this.board,
    required this.date,
    required this.stats,
    required this.canOfferAd,
    required this.onWatchAd,
    required this.adBusy,
    this.onMainMenu,
    this.friendCode,
    this.ensureFriendCode,
    this.newlyUnlocked = const {},
    this.nearMiss,
    this.xpGained = 0,
    this.level = 0,
    this.leveledUp = false,
    this.coinsEarned = 0,
    this.coinsDoubled = false,
    this.onDoubleCoins,
    this.coinsWon,
    this.shareText,
    this.sharer = const PlatformScoreSharer(),
    this.captureOverride,
    this.renderer = const RepaintBoundaryShareCardRenderer(),
    this.difficulty = Difficulty.easy,
    this.cosmetic = Cosmetic.classic,
    this.displayName,
    this.rank,
    this.onChallengeFriend,
    this.onSetRival,
  });

  @override
  State<ScoreShareScreen> createState() => _ScoreShareScreenState();
}

class _ScoreShareScreenState extends State<ScoreShareScreen> {
  final GlobalKey _cardKey = GlobalKey();
  late String? _resolvedFriendCode;

  BoardState get board => widget.board;
  String get date => widget.date;
  LifetimeStats get stats => widget.stats;
  bool get canOfferAd => widget.canOfferAd;
  VoidCallback get onWatchAd => widget.onWatchAd;
  ValueListenable<bool> get adBusy => widget.adBusy;
  VoidCallback? get onMainMenu => widget.onMainMenu;
  String? get friendCode => _resolvedFriendCode;
  Set<Achievement> get newlyUnlocked => widget.newlyUnlocked;
  String? get nearMiss => widget.nearMiss;
  int get xpGained => widget.xpGained;
  int get level => widget.level;
  bool get leveledUp => widget.leveledUp;
  int get coinsEarned => widget.coinsEarned;
  bool get coinsDoubled => widget.coinsDoubled;
  VoidCallback? get onDoubleCoins => widget.onDoubleCoins;
  ValueListenable<int>? get coinsWon => widget.coinsWon;
  Future<void> Function(String text)? get shareText => widget.shareText;
  ScoreSharer get sharer => widget.sharer;
  Future<Uint8List?> Function()? get captureOverride =>
      widget.captureOverride;
  ShareCardRenderer get renderer => widget.renderer;
  Difficulty get difficulty => widget.difficulty;
  Cosmetic get cosmetic => widget.cosmetic;
  String? get displayName => widget.displayName;
  int? get rank => widget.rank;
  Future<void> Function(String link)? get onChallengeFriend =>
      widget.onChallengeFriend;
  VoidCallback? get onSetRival => widget.onSetRival;

  @override
  void initState() {
    super.initState();
    _resolvedFriendCode = widget.friendCode;
  }

  @override
  void didUpdateWidget(ScoreShareScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.friendCode != oldWidget.friendCode) {
      _resolvedFriendCode = widget.friendCode;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        // Scrollable so the richer card + flair never overflow on short screens
        // (the card alone is tall); the LayoutBuilder keeps it vertically
        // centered when there's room to spare.
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Personal-only flair (near-miss, level-up, achievements) stays
                    // OUTSIDE the boundary so the shared PNG is a clean flex card.
                    RepaintBoundary(
                      key: _cardKey,
                      child: Center(
                        child: ShareCard(
                          board: board,
                          difficulty: difficulty,
                          score: board.score,
                          highestTier: board.highestTier,
                          streak: stats.streak,
                          level: level,
                          displayName: displayName,
                          rank: rank,
                          cosmetic: cosmetic,
                          friendCode: friendCode,
                          inviteLink: friendCode == null
                              ? null
                              : FriendsService.inviteHttpsLink(friendCode!),
                        ),
                      ),
                    ),
                    if (xpGained > 0) ...[
                      const SizedBox(height: 16),
                      _xpRow(),
                    ],
                    if (nearMiss != null) ...[
                      const SizedBox(height: 16),
                      Text(nearMiss!,
                          key: const Key('near-miss-line'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.amberAccent,
                              fontSize: 15,
                              fontWeight: FontWeight.w700)),
                    ],
                    if (leveledUp) ...[
                      const SizedBox(height: 12),
                      _levelUpBanner(),
                    ],
                    if (newlyUnlocked.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      _achievementsBanner(),
                    ],
                    const SizedBox(height: 24),
                    if (coinsWon != null)
                      _coinsSummary()
                    else if (coinsEarned > 0 &&
                        !coinsDoubled &&
                        onDoubleCoins != null)
                      AdBusyGate(
                        busy: adBusy,
                        onPressed: onDoubleCoins,
                        builder: (context, onPressed) => FilledButton.tonal(
                          key: const Key('double-coins-button'),
                          onPressed: onPressed,
                          child: Text('Watch ad: double $coinsEarned coins'),
                        ),
                      ),
                    if (canOfferAd)
                      AdBusyGate(
                        busy: adBusy,
                        onPressed: onWatchAd,
                        builder: (context, onPressed) => FilledButton.tonal(
                          onPressed: onPressed,
                          child: const Text('Watch ad for more moves'),
                        ),
                      ),
                    const SizedBox(height: 8),
                    FilledButton(
                      key: const Key('share-card-button'),
                      onPressed: () => _share(context),
                      child: const Text('Share'),
                    ),
                    if (onMainMenu != null) ...[
                      const SizedBox(height: 8),
                      OutlinedButton(
                        key: const Key('main-menu-button'),
                        onPressed: onMainMenu,
                        child: const Text('Main Menu'),
                      ),
                    ],
                    if (onChallengeFriend != null && displayName != null) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        key: const Key('challenge-friend-button'),
                        onPressed: () => _challenge(context),
                        icon: const Icon(Icons.sports_kabaddi),
                        label: const Text('Challenge a friend'),
                      ),
                    ],
                    if (onSetRival != null) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        key: const Key('set-rival-button'),
                        onPressed: onSetRival,
                        icon: const Icon(Icons.flag),
                        label: const Text('Set as rival'),
                      ),
                    ],
                    if (friendCode != null ||
                        widget.ensureFriendCode != null) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        key: const Key('invite-friend-button'),
                        onPressed: () => _invite(context),
                        icon: const Icon(Icons.person_add),
                        label: const Text('Invite a friend'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<Uint8List?> _capture() async {
    final override = captureOverride;
    if (override != null) return override();
    final ctx = _cardKey.currentContext;
    if (ctx == null) return null;
    return renderer.capture(ctx);
  }

  /// Build + share this run's result as a duel challenge link a friend can open
  /// to play the SAME seeded board. The score in the link is display-only.
  Future<void> _challenge(BuildContext context) async {
    final name = displayName;
    final cb = onChallengeFriend;
    if (name == null || cb == null) return;
    final challenge = DuelChallenge(
      date: date,
      difficulty: difficulty,
      challengerName: name,
      challengerScore: board.score,
    );
    await cb(challenge.toUri().toString());
  }

  Future<void> _share(BuildContext context) async {
    await _ensureFriendCode();
    final png = await _capture();
    if (png == null) {
      // Render failed (boundary not painted / capture threw): degrade to the
      // existing text share rather than failing outright (spec error-handling).
      final share = shareText ?? _nativeShare;
      await share(_textSummary());
      return;
    }
    final text = _textSummary();
    final reached = await sharer.shareToFacebook(png, text: text);
    if (!reached) await sharer.shareToSheet(png, text: text);
  }

  /// A plain-text fallback summary of the result, used when the rendered card
  /// can't be captured.
  String _textSummary() {
    final buf = StringBuffer('Connect Merge — ${difficulty.label}: '
        'scored ${board.score} (best tile ${1 << board.highestTier})');
    if (stats.streak > 0) buf.write(', streak ${stats.streak}');
    final code = friendCode;
    if (code != null) {
      buf
        ..writeln()
        ..write(FriendsService.inviteMessage(code, name: displayName));
    }
    return buf.toString();
  }

  Future<void> _invite(BuildContext context) async {
    final code = await _ensureFriendCode();
    if (code == null) return;
    final text = FriendsService.inviteMessage(code, name: displayName);
    final share = shareText ?? _nativeShare;
    await share(text);
  }

  Future<String?> _ensureFriendCode() async {
    final loader = widget.ensureFriendCode;
    if (loader == null) return friendCode;
    try {
      final code = (await loader()).trim();
      if (code.isEmpty || !mounted) return friendCode;
      setState(() => _resolvedFriendCode = code);
      await WidgetsBinding.instance.endOfFrame;
      return code;
    } catch (_) {
      return friendCode;
    }
  }

  /// Native share sheet via share_plus (device). Used in production when no
  /// [shareText] seam is injected.
  static Future<void> _nativeShare(String text) => SharePlus.instance
      .share(ShareParams(text: text, subject: 'Connect Merge'));

  /// Live coins summary (Phase 2): the run's winnings (doubling when the ad is
  /// watched) and the player's current total. Driven by the cubit's [coinsWon]
  /// observable so the reward the player watched an ad for is reflected reliably
  /// — not lost with an ephemeral setState across the fullscreen-ad round-trip.
  Widget _coinsSummary() => ValueListenableBuilder<int>(
        valueListenable: coinsWon!,
        builder: (context, won, _) {
          // The base is [coinsEarned]; once doubled the winnings are twice that.
          final doubled = won > coinsEarned;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Winnings flip from "+N" to "+2N" when the double-coins ad plays.
              Text(
                'Won: +$won coins',
                key: const Key('coins-won-line'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.amberAccent,
                    fontSize: 18,
                    fontWeight: FontWeight.w800),
              ),
              if (coinsEarned > 0 && !doubled && onDoubleCoins != null) ...[
                const SizedBox(height: 8),
                AdBusyGate(
                  busy: adBusy,
                  onPressed: onDoubleCoins,
                  builder: (context, onPressed) => FilledButton.tonal(
                    key: const Key('double-coins-button'),
                    onPressed: onPressed,
                    child: const Text('Watch ad: double your coins'),
                  ),
                ),
              ],
            ],
          );
        },
      );

  Widget _xpRow() => Row(
        key: const Key('xp-row'),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          LevelBadge(level: level),
          if (xpGained > 0) ...[
            const SizedBox(width: 10),
            Text('+$xpGained XP',
                key: const Key('xp-gained-line'),
                style: const TextStyle(
                    color: Colors.amberAccent,
                    fontSize: 16,
                    fontWeight: FontWeight.w800)),
          ],
        ],
      );

  Widget _levelUpBanner() => Container(
        key: const Key('level-up-banner'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.amberAccent, width: 1.5),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.arrow_circle_up, color: Colors.amberAccent),
            const SizedBox(width: 8),
            Text('Level up! You reached level $level',
                style: const TextStyle(
                    color: Colors.amberAccent, fontWeight: FontWeight.w800)),
          ],
        ),
      );

  Widget _achievementsBanner() => Container(
        key: const Key('newly-unlocked-banner'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.amberAccent, width: 1.5),
        ),
        child: Column(
          children: [
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.emoji_events, color: Colors.amberAccent, size: 20),
                SizedBox(width: 6),
                Text('Achievement unlocked!',
                    style: TextStyle(
                        color: Colors.amberAccent,
                        fontWeight: FontWeight.w800)),
              ],
            ),
            const SizedBox(height: 6),
            for (final a in newlyUnlocked)
              Text(a.label,
                  key: Key('unlocked-${a.name}'),
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
          ],
        ),
      );
}
