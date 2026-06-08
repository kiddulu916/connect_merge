import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:share_plus/share_plus.dart';

import '../../domain/models/achievement.dart';
import '../../domain/models/board_state.dart';
import '../../infrastructure/friends_service.dart';
import '../../infrastructure/score_sharer.dart';
import '../../infrastructure/storage_service.dart';

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

  /// Seam: text-only native share, used only by the [_invite] flow.
  /// Production falls through to [_nativeShare]; tests inject a fake.
  final Future<void> Function(String text)? shareText;

  /// Performs the actual score share. Production uses [PlatformScoreSharer];
  /// tests inject a fake.
  final ScoreSharer sharer;

  /// Test seam: returns the PNG bytes to share, bypassing real rendering.
  /// Production leaves this null and captures the on-screen card.
  final Future<Uint8List?> Function()? captureOverride;

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
    this.shareText,
    this.sharer = const PlatformScoreSharer(),
    this.captureOverride,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF12141C),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              RepaintBoundary(
                key: _cardKey,
                child: Container(
                  color: const Color(0xFF12141C),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('Daily Result',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 28,
                              fontWeight: FontWeight.w800)),
                      const SizedBox(height: 24),
                      _bigStat('SCORE', '${board.score}'),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _smallStat('BEST TILE', '${1 << board.highestTier}'),
                          _smallStat('MOVES', '${board.movesMade}'),
                          _smallStat('STREAK', '${stats.streak}'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _smallStat('BEST EVER', '${stats.bestScore}'),
                      if (newlyUnlocked.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        _achievementsBanner(),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
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
    );
  }

  Future<Uint8List?> _capture() async {
    final override = captureOverride;
    if (override != null) return override();
    final ctx = _cardKey.currentContext;
    if (ctx == null) return null;
    final boundary = ctx.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 3.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  }

  Future<void> _share(BuildContext context) async {
    final png = await _capture();
    if (png == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't prepare the image to share.")),
        );
      }
      return;
    }
    final reached = await sharer.shareToFacebook(png);
    if (!reached) await sharer.shareToSheet(png);
  }

  Future<void> _invite(BuildContext context) async {
    final code = friendCode;
    if (code == null) return;
    final text = 'Add me on Merge Loop! ${FriendsService.inviteLink(code)}';
    final share = shareText ?? _nativeShare;
    await share(text);
  }

  /// Native share sheet via share_plus (device). Used in production when no
  /// [shareText] seam is injected.
  static Future<void> _nativeShare(String text) =>
      Share.share(text, subject: 'Merge Loop');

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

  Widget _bigStat(String label, String value) => Column(
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white54, letterSpacing: 2)),
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 48,
                  fontWeight: FontWeight.w900)),
        ],
      );

  Widget _smallStat(String label, String value) => Column(
        children: [
          Text(label,
              style: const TextStyle(
                  color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700)),
        ],
      );
}
