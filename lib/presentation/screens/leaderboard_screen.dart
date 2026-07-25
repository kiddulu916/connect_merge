import 'package:flutter/material.dart';

import '../../domain/date_utils.dart' show formatDate, mondayOfWeek, utcToday;
import '../../domain/models/difficulty.dart';
import '../../domain/models/weekly_prize.dart';
import '../../infrastructure/friends_service.dart';
import '../../infrastructure/leaderboard_service.dart';
import '../theme/tokens.dart';
import '../widgets/tutorial_spotlight.dart';
import 'leaderboard/leaderboard_tutorial_mixin.dart';
import 'leaderboard/tier_board.dart';

/// Which board the user is viewing within a tier.
enum LeaderboardScope { global, friends }

/// Time period for a board. Daily uses the per-day RPC; the rest use a
/// read-only period aggregation (sum of daily bests).
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

  /// Renders step 7 of the first-launch tour over controls owned by this route.
  final bool tutorialMode;

  const LeaderboardScreen({
    super.key,
    required this.service,
    this.friendsService,
    this.initialDifficulty = Difficulty.easy,
    this.todayProvider,
    this.weeklyPrizes = const [],
    this.tutorialMode = false,
  });

  String today() => (todayProvider ?? utcToday)();

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen>
    with SingleTickerProviderStateMixin, LeaderboardTutorialMixin {
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
    if (widget.tutorialMode) {
      initTutorial();
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showToggle = widget.friendsService != null;
    final scaffold = Scaffold(
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
            KeyedSubtree(
              key: scopeTutorialKey,
              child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                  )),
            ),
          // Challenge is daily-only in both scopes.
          if (Difficulty.values[_tabs.index] != Difficulty.challenge)
            KeyedSubtree(
              key: periodTutorialKey,
              child: Padding(
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
                  )),
            ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                for (final d in Difficulty.values)
                  TierBoard(
                    key: ValueKey(
                        'board-${d.name}-${_scope.name}-${_period.name}'),
                    service: widget.service,
                    friendsService: widget.friendsService,
                    scope: _scope,
                    period: _period,
                    difficulty: d,
                    date: widget.today(),
                    weeklyPrizes: widget.weeklyPrizes,
                    tutorialRowKey: widget.tutorialMode &&
                            d == Difficulty.values[_tabs.index]
                        ? rowTutorialKey
                        : null,
                    onRowsAvailable: widget.tutorialMode &&
                            d == Difficulty.values[_tabs.index]
                        ? setRowsAvailable
                        : null,
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
                        title: Text('${p.tier.label} — Week of ${p.weekStart}',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 13)),
                        trailing: Text('#${p.rank}',
                            style: const TextStyle(color: Colors.white54)),
                        dense: true,
                      ),
                    )
                    .toList(),
              ),
            ),
        ],
      ),
    );
    if (!widget.tutorialMode) return scaffold;
    final target = currentTutorialTarget;
    final copy = tutorialCopy(target);
    final fallback = isRowFallback;
    return PopScope(
      canPop: allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) finishTutorial(TutorialResult.skipped);
      },
      child: Stack(
        children: [
          AbsorbPointer(child: ExcludeSemantics(child: scaffold)),
          Positioned.fill(
            child: KeyedSubtree(
              key: fallback ? const Key('tutorial-text-fallback') : null,
              child: TutorialSpotlight(
                targetRect: tutorialRect,
                stepLabel: 'step-7',
                title: copy.$1,
                body: copy.$2,
                onSkip: () => finishTutorial(TutorialResult.skipped),
                onNext: tutorialAdvancing ? null : nextTutorialTarget,
                nextLabel: target == TutorialTarget.row ? 'Finish' : 'Next',
              ),
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
