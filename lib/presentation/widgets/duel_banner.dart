import 'package:flutter/material.dart';

import '../../domain/models/duel_challenge.dart';
import '../theme/tokens.dart';

/// "You were challenged — play this board" call-to-action (Phase 3).
///
/// Shows the challenger's claimed score, LABELLED as *their claim* so the
/// display-only nature of the link is honest (a forged link can't be trusted,
/// and ranking lives in the verified leaderboard). When the challenged board is
/// no longer today, it instead shows an expired state and offers today's tier.
class DuelBanner extends StatelessWidget {
  final DuelChallenge challenge;

  /// True when the challenged date is no longer playable (board is gone).
  final bool expired;

  /// Tapped to play the challenged board (non-expired).
  final VoidCallback? onPlay;

  /// Tapped to play today's board of the same tier instead (expired).
  final VoidCallback? onPlayToday;

  /// Dismiss the banner.
  final VoidCallback? onDismiss;

  const DuelBanner({
    super.key,
    required this.challenge,
    this.expired = false,
    this.onPlay,
    this.onPlayToday,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('duel-banner'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.cyanAccent, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.sports_kabaddi, color: Colors.cyanAccent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  expired
                      ? 'Challenge expired'
                      : '${challenge.challengerName} challenged you!',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w800),
                ),
              ),
              if (onDismiss != null)
                IconButton(
                  key: const Key('duel-dismiss'),
                  visualDensity: VisualDensity.compact,
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            expired
                ? 'That board is gone, but you can take on today\'s '
                    '${challenge.difficulty.label} board.'
                // "their claim" framing: display-only, not authoritative.
                : 'Their claim: ${challenge.challengerScore} on '
                    '${challenge.difficulty.label}. Beat the same board.',
            key: const Key('duel-claim-line'),
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 10),
          if (expired)
            FilledButton(
              key: const Key('duel-play-today'),
              onPressed: onPlayToday,
              child: Text('Play today\'s ${challenge.difficulty.label}'),
            )
          else
            FilledButton(
              key: const Key('duel-play'),
              onPressed: onPlay,
              child: const Text('Play this board'),
            ),
        ],
      ),
    );
  }
}
