import 'package:flutter/material.dart';

import '../../application/game_cubit.dart' show formatDate;
import '../../domain/models/day_result.dart';
import '../../domain/models/difficulty.dart';
import '../theme/tile_palette.dart';
import '../theme/tokens.dart';

/// Wordle-style month grid of past daily results (Phase 4). Pure presentation:
/// the caller passes the full append-only [history] (from
/// `StorageService.loadHistory()`); this screen lets the player pick a tier and
/// a month and renders one coloured cell per played day.
///
/// A day with a result is tinted/intensified by its highest tier (so outcome
/// QUALITY reads at a glance, Wordle-stat style — never a win/loss, since the
/// game is a high-score chase); a missed day is a dim placeholder. Tapping a day
/// shows its score/tier and factual end state (out-of-moves vs deadlock).
class StatsCalendarScreen extends StatefulWidget {
  /// All persisted results, any order. Indexed here by `(date, difficulty)`.
  final List<DayResult> history;

  /// Which tier to show first. Defaults to the first difficulty.
  final Difficulty initialDifficulty;

  const StatsCalendarScreen({
    super.key,
    required this.history,
    this.initialDifficulty = Difficulty.easy,
  });

  @override
  State<StatsCalendarScreen> createState() => _StatsCalendarScreenState();
}

class _StatsCalendarScreenState extends State<StatsCalendarScreen> {
  late Difficulty _difficulty;

  /// First day of the month currently shown (day component is always 1).
  late DateTime _month;

  @override
  void initState() {
    super.initState();
    _difficulty = widget.initialDifficulty;
    final now = DateTime.now().toUtc();
    _month = DateTime.utc(now.year, now.month);
  }

  /// Results for the selected tier, keyed by canonical `YYYY-MM-DD` date. A
  /// later entry for the same key wins (defensive; there is normally one).
  Map<String, DayResult> get _byDate {
    final out = <String, DayResult>{};
    for (final r in widget.history) {
      if (r.difficulty == _difficulty) out[r.date] = r;
    }
    return out;
  }

  static const _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  void _shiftMonth(int delta) {
    setState(() => _month = DateTime.utc(_month.year, _month.month + delta));
  }

  void _showDay(DayResult r) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(r.date, style: const TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Score: ${r.score}',
                style: const TextStyle(color: Colors.white70)),
            Text('Highest tile: ${1 << r.highestTier}',
                style: const TextStyle(color: Colors.white70)),
            // Factual end state — NOT a win/loss (the game is a high-score
            // chase; a high-scoring deadlock is still a strong day).
            Text(
                r.endedOutOfMoves
                    ? 'Ran out of moves'
                    : 'Ended in a deadlock',
                style: const TextStyle(color: Colors.white54)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final byDate = _byDate;
    final daysInMonth = DateTime.utc(_month.year, _month.month + 1, 0).day;
    // Monday-first weekday offset (Dart weekday: Mon=1..Sun=7).
    final leading = DateTime.utc(_month.year, _month.month, 1).weekday - 1;
    final totalCells = leading + daysInMonth;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        foregroundColor: Colors.white,
        title: const Text('Stats calendar'),
      ),
      body: Column(
        children: [
          const SizedBox(height: 12),
          // Tier selector.
          SizedBox(
            height: 40,
            child: ListView(
              key: const Key('stats-tier-selector'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final d in Difficulty.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      key: Key('stats-tier-${d.name}'),
                      label: Text(d.label),
                      selected: d == _difficulty,
                      onSelected: (_) => setState(() => _difficulty = d),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Month navigation.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                key: const Key('stats-prev-month'),
                icon: const Icon(Icons.chevron_left, color: Colors.white70),
                onPressed: () => _shiftMonth(-1),
              ),
              SizedBox(
                width: 160,
                child: Text(
                  '${_monthNames[_month.month - 1]} ${_month.year}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                key: const Key('stats-next-month'),
                icon: const Icon(Icons.chevron_right, color: Colors.white70),
                onPressed: () => _shiftMonth(1),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: GridView.builder(
              key: const Key('stats-calendar-grid'),
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
              ),
              itemCount: totalCells,
              itemBuilder: (context, i) {
                if (i < leading) return const SizedBox.shrink();
                final day = i - leading + 1;
                final key = formatDate(DateTime.utc(_month.year, _month.month, day));
                final result = byDate[key];
                return _DayCell(
                  day: day,
                  result: result,
                  onTap: result == null ? null : () => _showDay(result),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  final int day;
  final DayResult? result;
  final VoidCallback? onTap;

  const _DayCell({required this.day, required this.result, this.onTap});

  @override
  Widget build(BuildContext context) {
    final r = result;
    final hasResult = r != null;
    // Tint a played day by its highest tier so a strong day reads at a glance —
    // outcome QUALITY, never win/loss (a high-scoring deadlock is a good day).
    // A higher tier gets a stronger (more opaque) tint.
    final color = hasResult
        ? TilePalette.colorForTier(r.highestTier)
        : AppColors.surface;
    final opacity =
        hasResult ? (0.45 + 0.05 * r.highestTier).clamp(0.45, 1.0) : 1.0;
    return GestureDetector(
      key: Key('stats-day-$day'),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: hasResult ? color.withValues(alpha: opacity) : color,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(
          '$day',
          style: TextStyle(
            color: hasResult ? Colors.white : Colors.white30,
            fontSize: 12,
            fontWeight: hasResult ? FontWeight.w800 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
