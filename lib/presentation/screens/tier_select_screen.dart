import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../application/game_cubit.dart';
import '../../domain/models/difficulty.dart';
import '../../infrastructure/ad_service.dart';
import '../../infrastructure/storage_service.dart';
import '../theme/tile_palette.dart';
import 'game_screen.dart';

/// Entry screen: pick a difficulty tier. Each card shows the starting tile
/// count, whether the tier is already done today, and a live countdown to the
/// 00:00 UTC reset.
class TierSelectScreen extends StatefulWidget {
  final StorageService storage;
  final AdService adService;

  /// Override for tests; defaults to the real UTC date string.
  final String Function()? todayProvider;

  /// Override for tests to intercept tier selection instead of pushing the
  /// game route (which would load the ad plugin). When null, pushes GameScreen.
  final void Function(BuildContext context, Difficulty difficulty)?
      onTierSelected;

  const TierSelectScreen({
    super.key,
    required this.storage,
    required this.adService,
    this.todayProvider,
    this.onTierSelected,
  });

  String today() => (todayProvider ?? utcToday)();

  @override
  State<TierSelectScreen> createState() => _TierSelectScreenState();
}

class _TierSelectScreenState extends State<TierSelectScreen> {
  Timer? _ticker;
  Duration _untilReset = Duration.zero;

  @override
  void initState() {
    super.initState();
    _untilReset = _computeUntilReset();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _untilReset = _computeUntilReset());
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Duration _computeUntilReset() {
    final now = DateTime.now().toUtc();
    final nextMidnight = DateTime.utc(now.year, now.month, now.day)
        .add(const Duration(days: 1));
    return nextMidnight.difference(now);
  }

  String _fmt(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  bool _isCompleted(Difficulty d) {
    final today = widget.today();
    return widget.storage.loadSnapshot(today, d)?.completed ?? false;
  }

  void _startTier(BuildContext context, Difficulty difficulty) {
    final override = widget.onTierSelected;
    if (override != null) {
      override(context, difficulty);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BlocProvider(
          create: (_) => GameCubit(storage: widget.storage)
            ..init(difficulty: difficulty),
          child: GameScreen(adService: widget.adService),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF12141C),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              const Text('Merge Loop',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              const Text('Choose your daily challenge',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 14)),
              const SizedBox(height: 8),
              Text('Resets in ${_fmt(_untilReset)} (UTC)',
                  key: const Key('reset-countdown'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 12,
                      letterSpacing: 1)),
              const SizedBox(height: 24),
              Expanded(
                child: ListView(
                  children: [
                    for (final d in Difficulty.values) _tierCard(context, d),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tierCard(BuildContext context, Difficulty d) {
    final completed = _isCompleted(d);
    // Use the tier's starting fill to pick a representative accent color.
    final accent = TilePalette.colorForTier(d.startingFill);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Material(
        color: const Color(0xFF1B1E2A),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: Key('tier-${d.name}'),
          borderRadius: BorderRadius.circular(16),
          onTap: completed ? null : () => _startTier(context, d),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: completed ? 0.3 : 1.0),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: Text('${d.startingFill}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d.label,
                          style: TextStyle(
                              color: completed ? Colors.white54 : Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text('${d.startingFill} starting tiles',
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 13)),
                    ],
                  ),
                ),
                if (completed)
                  const Text('Done today ✓',
                      style: TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 13,
                          fontWeight: FontWeight.w700))
                else
                  const Icon(Icons.chevron_right, color: Colors.white54),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
