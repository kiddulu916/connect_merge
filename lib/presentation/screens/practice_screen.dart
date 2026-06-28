import 'package:flutter/material.dart';

import '../../domain/engine/game_engine.dart';
import '../../domain/engine/prng.dart';
import '../../domain/models/board_state.dart';
import '../../domain/models/cosmetic.dart';
import '../../domain/models/difficulty.dart';
import '../../domain/models/game_status.dart';
import '../../infrastructure/ad_service.dart';
import '../../infrastructure/practice_seeder.dart';
import '../widgets/banner_slot.dart';
import '../theme/tokens.dart';
import '../widgets/board_widget.dart';
import '../widgets/moves_counter.dart';

/// Off-leaderboard endless play. Each round is a freshly RANDOM-seeded board
/// (via [PracticeSeeder]); "Play again" generates a new one.
///
/// FAIRNESS INVARIANT: practice mode has NO submit/leaderboard path. This widget
/// deliberately imports neither LeaderboardService nor FriendsService and never
/// records a score. Completing a round only offers a replay. (Asserted in a
/// test that scans for any submit/score-write reference.)
class PracticeScreen extends StatefulWidget {
  final Difficulty difficulty;
  final AdService adService;

  /// Selected tile theme (cosmetics also apply in practice). Defaults to classic.
  final Cosmetic cosmetic;

  /// Seam for deterministic tests.
  final PracticeSeeder? seeder;

  const PracticeScreen({
    super.key,
    required this.difficulty,
    required this.adService,
    this.cosmetic = Cosmetic.classic,
    this.seeder,
  });

  @override
  State<PracticeScreen> createState() => _PracticeScreenState();
}

class _PracticeScreenState extends State<PracticeScreen> {
  late final PracticeSeeder _seeder;
  late BoardState _board;
  late List<int> _dropTiers;
  late Prng _landing;

  @override
  void initState() {
    super.initState();
    _seeder = widget.seeder ?? PracticeSeeder();
    _newRound();
  }

  void _newRound() {
    final round = _seeder.generate(widget.difficulty);
    setState(() {
      _board = round.start.board;
      _dropTiers = round.start.dropTiers;
      _landing = round.landing;
    });
  }

  void _playChain(List<int> path) {
    if (_board.status != GameStatus.playing) return;
    if (!GameEngine.isValidChain(_board, path)) return;

    var board = GameEngine.collapseChain(_board, path);
    // Refill toward the difficulty's starting fill using the practice drop list.
    // The index guard prevents overrunning the fixed list; when exhausted we stop.
    while (board.filledCount < widget.difficulty.startingFill &&
        board.emptyIndices.isNotEmpty &&
        board.dropIndex < _dropTiers.length) {
      board = GameEngine.applyDrop(board, _dropTiers[board.dropIndex], _landing);
    }
    board = GameEngine.evaluateStatus(board);
    setState(() => _board = board);
    // NOTE: no submit, no score write — practice is intentionally off-board.
  }

  @override
  Widget build(BuildContext context) {
    final done = _board.status != GameStatus.playing;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        foregroundColor: Colors.white,
        title: const Text('Practice'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    const Text('PRACTICE • OFF-LEADERBOARD',
                        key: Key('practice-label'),
                        style: TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                            letterSpacing: 2,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    MovesCounter(
                        movesRemaining: _board.movesRemaining,
                        score: _board.score),
                    const SizedBox(height: 24),
                    Expanded(
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: BoardWidget(
                            board: _board,
                            onChain: _playChain,
                            cosmetic: widget.cosmetic,
                          ),
                        ),
                      ),
                    ),
                    if (done)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: FilledButton(
                          key: const Key('practice-play-again'),
                          onPressed: _newRound,
                          child: const Text('Play again'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            BannerSlot(adService: widget.adService),
          ],
        ),
      ),
    );
  }
}
