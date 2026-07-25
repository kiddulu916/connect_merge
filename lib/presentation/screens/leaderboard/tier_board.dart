import 'package:flutter/material.dart';

import '../../../domain/models/difficulty.dart';
import '../../../domain/models/leaderboard_entry.dart';
import '../../../domain/models/weekly_prize.dart';
import '../../../infrastructure/friends_service.dart';
import '../../../infrastructure/leaderboard_service.dart';
import '../../widgets/leaderboard_row.dart';
import '../leaderboard_screen.dart'
    show LeaderboardPeriod, LeaderboardPeriodX, LeaderboardScope;

/// One tier's leaderboard tab: loads and renders ranked rows for the given
/// [scope]/[period]/[difficulty]/[date], with pull-to-refresh and
/// loading/empty/error states. Extracted from leaderboard_screen.dart.
class TierBoard extends StatefulWidget {
  final LeaderboardService service;
  final FriendsService? friendsService;
  final LeaderboardScope scope;
  final LeaderboardPeriod period;
  final Difficulty difficulty;
  final String date;
  final List<WeeklyPrize> weeklyPrizes;
  final GlobalKey? tutorialRowKey;
  final ValueChanged<bool>? onRowsAvailable;

  const TierBoard({
    super.key,
    required this.service,
    required this.friendsService,
    required this.scope,
    required this.period,
    required this.difficulty,
    required this.date,
    this.weeklyPrizes = const [],
    this.tutorialRowKey,
    this.onRowsAvailable,
  });

  @override
  State<TierBoard> createState() => _TierBoardState();
}

class _TierBoardState extends State<TierBoard>
    with AutomaticKeepAliveClientMixin {
  late Future<List<LeaderboardEntry>> _future;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _future = _startLoad();
  }

  Future<List<LeaderboardEntry>> _startLoad() {
    final future = _load();
    future.then<void>(
      (entries) {
        if (mounted) widget.onRowsAvailable?.call(entries.isNotEmpty);
      },
      onError: (Object _, StackTrace __) {
        if (mounted) widget.onRowsAvailable?.call(false);
      },
    );
    return future;
  }

  Future<List<LeaderboardEntry>> _load() {
    final period = widget.difficulty == Difficulty.challenge
        ? LeaderboardPeriod.daily
        : widget.period;
    if (widget.scope == LeaderboardScope.friends &&
        widget.friendsService != null) {
      if (period == LeaderboardPeriod.daily) {
        return widget.friendsService!.friendsLeaderboard(
          difficulty: widget.difficulty,
          date: widget.date,
        );
      }
      final (from, to) = period.range(widget.date);
      return widget.friendsService!.friendsLeaderboardPeriod(
        difficulty: widget.difficulty,
        from: from,
        to: to,
      );
    }
    // Global scope: daily uses the per-day RPC; weekly/monthly/all-time use the
    // read-only period aggregation (sum of daily bests).
    if (period == LeaderboardPeriod.daily) {
      return widget.service
          .fetch(difficulty: widget.difficulty, date: widget.date);
    }
    final (from, to) = period.range(widget.date);
    return widget.service
        .fetchPeriod(difficulty: widget.difficulty, from: from, to: to);
  }

  Future<void> _refresh() async {
    setState(() => _future = _startLoad());
    await _future;
  }

  /// Returns the prize indicator suffix for challenge-board rows.
  /// Ranks 1-3 get 🏆; ranks 4-10 get ✦; others get null.
  String? _challengeSuffix(int rank) {
    if (rank <= 3) return '\u{1F3C6}';
    if (rank <= 10) return '✶';
    return null;
  }

  /// Returns the crown emoji for "me" rows that have a matching weekly prize
  /// on this tier. Returns null for other players or when there is no prize.
  String? _weekCrown(LeaderboardEntry entry) {
    if (!entry.isMe) return null;
    for (final prize in widget.weeklyPrizes) {
      if (prize.tier == widget.difficulty) {
        return switch (prize.rank) {
          1 => '\u{1F947}',
          2 => '\u{1F948}',
          3 => '\u{1F949}',
          4 || 5 => '\u{1F3C5}',
          _ => null,
        };
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isFriends = widget.scope == LeaderboardScope.friends;
    return FutureBuilder<List<LeaderboardEntry>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
              child: CircularProgressIndicator(color: Colors.deepPurpleAccent));
        }
        if (snap.hasError) {
          return _Message(
            key: const Key('lb-error'),
            text: "Couldn't load the leaderboard.\nPull to retry.",
            onRetry: _refresh,
          );
        }
        final allEntries = snap.data ?? const <LeaderboardEntry>[];
        // All board RPCs are capped at 100; retain a client-side backstop.
        final entries = widget.difficulty == Difficulty.challenge
            ? allEntries.take(100).toList()
            : allEntries;
        if (entries.isEmpty) {
          return _Message(
            key: const Key('lb-empty'),
            text: isFriends
                ? 'No friends on the board yet.\nInvite some!'
                : 'No scores yet today.\nBe the first!',
            onRetry: _refresh,
          );
        }
        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView.builder(
            key: const Key('lb-list'),
            itemCount: entries.length,
            itemBuilder: (context, i) {
              final entry = entries[i];
              final row = LeaderboardRow(
                entry: entry,
                crownEmoji: _weekCrown(entry),
                prizeSuffix: widget.difficulty == Difficulty.challenge
                    ? _challengeSuffix(entry.rank)
                    : null,
              );
              if (i != 0 || widget.tutorialRowKey == null) return row;
              return KeyedSubtree(key: widget.tutorialRowKey, child: row);
            },
          ),
        );
      },
    );
  }
}

class _Message extends StatelessWidget {
  final String text;
  final Future<void> Function() onRetry;
  const _Message({super.key, required this.text, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    // Wrap in a scrollable so RefreshIndicator works on the empty/error states.
    return RefreshIndicator(
      onRefresh: onRetry,
      child: ListView(
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.3),
          Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 16)),
        ],
      ),
    );
  }
}
