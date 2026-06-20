import 'dart:typed_data';

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
import '../widgets/level_badge.dart';
import '../widgets/share_card.dart';

/// Offline daily result: the player's own score/tier/moves plus local personal
/// stats. The emoji share is the (offline) comparison mechanism. When a friend
/// code is available, the share card carries an invite link and a dedicated
/// "invite a friend" CTA is shown (Phase 3 growth lever).
class ScoreShareScreen extends StatelessWidget {
  /// Wraps the visual card so it can be rasterised for sharing.
  final GlobalKey _cardKey = GlobalKey();
  final BoardState board;
  final String date;
  final LifetimeStats stats;
  final bool canOfferAd;
  final VoidCallback onWatchAd;

  /// Returns to the main menu (tier select). When null, no button is shown.
  final VoidCallback? onMainMenu;

  /// The player's friend code, when online. When present, the share text
  /// includes an invite link and an "Invite a friend" CTA is shown.
  final String? friendCode;

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

  ScoreShareScreen({
    super.key,
    required this.board,
    required this.date,
    required this.stats,
    required this.canOfferAd,
    required this.onWatchAd,
    this.onMainMenu,
    this.friendCode,
    this.newlyUnlocked = const {},
    this.nearMiss,
    this.xpGained = 0,
    this.level = 0,
    this.leveledUp = false,
    this.coinsEarned = 0,
    this.coinsDoubled = false,
    this.onDoubleCoins,
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
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF12141C),
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
              // The richer rendered share card (Phase 3) is the captured image.
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
              if (coinsEarned > 0 && !coinsDoubled && onDoubleCoins != null)
                FilledButton.tonal(
                  key: const Key('double-coins-button'),
                  onPressed: onDoubleCoins,
                  child: Text('Watch ad: double $coinsEarned coins'),
                ),
              if (canOfferAd)
                FilledButton.tonal(
                  onPressed: onWatchAd,
                  child: const Text('Watch ad for more moves'),
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
              if (friendCode != null) ...[
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
    final png = await _capture();
    if (png == null) {
      // Render failed (boundary not painted / capture threw): degrade to the
      // existing text share rather than failing outright (spec error-handling).
      final share = shareText ?? _nativeShare;
      await share(_textSummary());
      return;
    }
    final reached = await sharer.shareToFacebook(png);
    if (!reached) await sharer.shareToSheet(png);
  }

  /// A plain-text fallback summary of the result, used when the rendered card
  /// can't be captured.
  String _textSummary() {
    final buf = StringBuffer('Merge Count — ${difficulty.label}: '
        'scored ${board.score} (best tile ${1 << board.highestTier})');
    if (stats.streak > 0) buf.write(', streak ${stats.streak}');
    return buf.toString();
  }

  Future<void> _invite(BuildContext context) async {
    final code = friendCode;
    if (code == null) return;
    final text = 'Add me on Merge Count! ${FriendsService.inviteLink(code)}';
    final share = shareText ?? _nativeShare;
    await share(text);
  }

  /// Native share sheet via share_plus (device). Used in production when no
  /// [shareText] seam is injected.
  static Future<void> _nativeShare(String text) => SharePlus.instance
      .share(ShareParams(text: text, subject: 'Merge Count'));

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
          color: const Color(0xFF1B1E2A),
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
          color: const Color(0xFF1B1E2A),
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
