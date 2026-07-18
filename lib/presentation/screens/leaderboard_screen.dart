import 'package:flutter/material.dart';

import '../../domain/date_utils.dart' show formatDate, mondayOfWeek, utcToday;
import '../../domain/models/difficulty.dart';
import '../../domain/models/leaderboard_entry.dart';
import '../../domain/models/weekly_prize.dart';
import '../../infrastructure/friends_service.dart';
import '../../infrastructure/leaderboard_service.dart';
import '../theme/tokens.dart';
import '../widgets/leaderboard_row.dart';

/// Which board the user is viewing within a tier.
enum LeaderboardScope { global, friends }

/// Time period for the global board. Daily uses the per-day RPC; the rest use
/// the read-only `leaderboard_period` aggregation (sum of daily bests).
enum LeaderboardPeriod { daily, weekly, monthly, allTime }

extension LeaderboardPeriodX on LeaderboardPeriod {
  String get label => switch (this) {
        LeaderboardPeriod.daily => 'Daily',
        LeaderboardPeriod.weekly => 'Weekly',
        LeaderboardPeriod.monthly => 'Monthly',
        LeaderboardPeriod.allTime => 'All-time',
      };

  /// Inclusive [from, to] UTC date range for [today]. Daily collapses to a
  /// single day; all-time spans from a fixed launch floor to today. [today]
  /// must be the canonical YYYY-MM-DD date used throughout the app.
  (String, String) range(String today) {
    final t = DateTime.parse(today);
    switch (this) {
      case LeaderboardPeriod.daily:
        return (today, today);
      case LeaderboardPeriod.weekly:
        // Calendar week: Monday of the current ISO week → today.
        // Prize checks use the previous completed week; both periods share
        // only this Monday-of-week sub-rule.
        return (mondayOfWeek(today), today);
      case LeaderboardPeriod.monthly:
        // Calendar month: 1st of the current month → today.
        return (formatDate(DateTime.utc(t.year, t.month, 1)), today);
      case LeaderboardPeriod.allTime:
        // Launch floor; well before any real score exists.
        return ('2020-01-01', today);
    }
  }
}

/// Per-tier daily leaderboard with tier tabs and a Global / Friends toggle.
/// Highlights the player's own row.
class LeaderboardScreen extends StatefulWidget {
  final LeaderboardService service;

  /// Friends board source. When null, the Global / Friends toggle is hidden and
  /// only the global board shows (offline / friends disabled).
  final FriendsService? friendsService;

  /// The tier shown first.
  final Difficulty initialDifficulty;

  /// Override for tests; defaults to the real UTC date string.
  final String Function()? todayProvider;

  /// The player's weekly prize history, used to show crown badges on "me" rows
  /// and the "Your Crowns" expandable section.
  final List<WeeklyPrize> weeklyPrizes;

  const LeaderboardScreen({
    super.key,
    required this.service,
    this.friendsService,
    this.initialDifficulty = Difficulty.easy,
    this.todayProvider,
    this.weeklyPrizes = const [],
  });

  String today() => (todayProvider ?? utcToday)();

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  LeaderboardScope _scope = LeaderboardScope.global;
  LeaderboardPeriod _period = LeaderboardPeriod.daily;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: Difficulty.values.length,
      vsync: this,
      initialIndex: Difficulty.values.indexOf(widget.initialDifficulty),
    );
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showToggle = widget.friendsService != null;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        foregroundColor: Colors.white,
        title: const Text('Leaderboard'),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          indicatorColor: Colors.deepPurpleAccent,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          tabs: [for (final d in Difficulty.values) Tab(text: d.label)],
        ),
      ),
      body: Column(
        children: [
          if (showToggle)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: SegmentedButton<LeaderboardScope>(
                key: const Key('lb-scope-toggle'),
                segments: const [
                  ButtonSegment(
                    value: LeaderboardScope.global,
                    label: Text('Global'),
                    icon: Icon(Icons.public),
                  ),
                  ButtonSegment(
                    value: LeaderboardScope.friends,
                    label: Text('Friends'),
                    icon: Icon(Icons.group),
                  ),
                ],
                selected: {_scope},
                onSelectionChanged: (s) => setState(() => _scope = s.first),
              ),
            ),
          // Period tabs apply only to the global board (the friends RPC is
          // daily-only). Hidden in Friends scope and on the challenge tab
          // (challenge is always daily-only).
          if (_scope == LeaderboardScope.global &&
              Difficulty.values[_tabs.index] != Difficulty.challenge)
            Padding(
              padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<LeaderboardPeriod>(
                  key: const Key('lb-period-tabs'),
                  segments: [
                    for (final p in LeaderboardPeriod.values)
                      ButtonSegment(value: p, label: Text(p.label)),
                  ],
                  selected: {_period},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) =>
                      setState(() => _period = s.first),
                ),
              ),
            ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                for (final d in Difficulty.values)
                  _TierBoard(
                    key: ValueKey(
                        'board-${d.name}-${_scope.name}-${_period.name}'),
                    service: widget.service,
                    friendsService: widget.friendsService,
                    scope: _scope,
                    period: _period,
                    difficulty: d,
                    date: widget.today(),
                    weeklyPrizes: widget.weeklyPrizes,
                  ),
              ],
            ),
          ),
          if (widget.weeklyPrizes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: ExpansionTile(
                title: const Text('Your Crowns',
                    style: TextStyle(color: Colors.white70)),
                iconColor: Colors.amber,
                collapsedIconColor: Colors.white54,
                children: widget.weeklyPrizes
                    .map(
                      (p) => ListTile(
                        leading: Text(_crownEmoji(p.rank),
                            style: const TextStyle(fontSize: 20)),
                        title: Text(
                            '${p.tier.label} — Week of ${p.weekStart}',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 13)),
                        trailing: Text('#${p.rank}',
                            style:
                                const TextStyle(color: Colors.white54)),
                        dense: true,
                      ),
                    )
                    .toList(),
              ),
            ),
        ],
      ),
    );
  }

  String _crownEmoji(int rank) => switch (rank) {
        1 => '\u{1F947}',
        2 => '\u{1F948}',
        3 => '\u{1F949}',
        _ => '\u{1F3C5}',
      };
}

class _TierBoard extends StatefulWidget {
  final LeaderboardService service;
  final FriendsService? friendsService;
  final LeaderboardScope scope;
  final LeaderboardPeriod period;
  final Difficulty difficulty;
  final String date;
  final List<WeeklyPrize> weeklyPrizes;

  const _TierBoard({
    super.key,
    required this.service,
    required this.friendsService,
    required this.scope,
    required this.period,
    required this.difficulty,
    required this.date,
    this.weeklyPrizes = const [],
  });

  @override
  State<_TierBoard> createState() => _TierBoardState();
}

class _TierBoardState extends State<_TierBoard>
    with AutomaticKeepAliveClientMixin {
  late Future<List<LeaderboardEntry>> _future;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<LeaderboardEntry>> _load() {
    if (widget.scope == LeaderboardScope.friends &&
        widget.friendsService != null) {
      return widget.friendsService!
          .friendsLeaderboard(difficulty: widget.difficulty, date: widget.date);
    }
    // Global scope: daily uses the per-day RPC; weekly/monthly/all-time use the
    // read-only period aggregation (sum of daily bests).
    if (widget.period == LeaderboardPeriod.daily) {
      return widget.service
          .fetch(difficulty: widget.difficulty, date: widget.date);
    }
    final (from, to) = widget.period.range(widget.date);
    return widget.service
        .fetchPeriod(difficulty: widget.difficulty, from: from, to: to);
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
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
        // Challenge board is capped at top-10.
        final entries = widget.difficulty == Difficulty.challenge
            ? allEntries.take(10).toList()
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
              return LeaderboardRow(
                entry: entry,
                crownEmoji: _weekCrown(entry),
                prizeSuffix: widget.difficulty == Difficulty.challenge
                    ? _challengeSuffix(entry.rank)
                    : null,
              );
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
