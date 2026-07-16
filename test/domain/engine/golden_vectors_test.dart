import 'dart:convert';
import 'dart:io';

import 'package:connect_merge/application/game_cubit.dart';
import 'package:connect_merge/application/game_state.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/engine/daily_seeder.dart';
import 'package:connect_merge/domain/engine/game_engine.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/challenge_rule.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/game_status.dart';
import 'package:connect_merge/domain/models/move.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixturePath = 'supabase/functions/_shared/golden_vectors.json';
const _baseDate = '2026-07-14';
const _maxDateSearchDays = 60;
const _maxChainSearchAttempts = 100000;
const _maxScriptedEvents = 64;

const _requiredVectorNames = <String>{
  'standard-easy',
  'standard-medium',
  'standard-hard',
  'standard-legendary',
  'challenge-budgetCut',
  'challenge-longChainsOnly',
  'challenge-denseStart',
  'challenge-sparseStart',
  'challenge-wallMaze',
  'challenge-comboRush',
  'standard-all-three-continues',
  'standard-no-continues',
};

const _requiredRejectionNames = <String>{
  'reject-fourth-continue',
  'reject-standard-post-budget-chain',
  'reject-budgetCut-post-budget-chain',
  'reject-non-budget-challenge-post-budget-chain',
  'reject-longChainsOnly-two-chain',
  'reject-legacy-merge-event',
};

void main() {
  test('Dart client runs match the committed dual-engine golden vectors',
      () async {
    if (Platform.environment['UPDATE_GOLDENS'] == '1') {
      await _generateFixture(
        force: Platform.environment['UPDATE_GOLDENS_FORCE'] == '1',
      );
    }

    final fixture = _readFixture();
    expect(fixture['season'], kLeaderboardSeason);

    final vectors = _recordList(fixture['vectors']);
    final rejections = _recordList(fixture['rejections']);
    expect(_namesOf(vectors), _requiredVectorNames);
    expect(_namesOf(rejections), _requiredRejectionNames);

    for (final rejection in rejections) {
      expect(_expectedOf(rejection)['valid'], isFalse,
          reason: rejection['name'] as String);
    }

    for (final vector in vectors) {
      await _assertVector(vector);
    }
  });
}

Map<String, dynamic> _readFixture() {
  final decoded = jsonDecode(File(_fixturePath).readAsStringSync());
  return Map<String, dynamic>.from(decoded as Map<String, dynamic>);
}

List<Map<String, dynamic>> _recordList(Object? value) => (value
        as List<dynamic>)
    .map((entry) => Map<String, dynamic>.from(entry as Map<String, dynamic>))
    .toList();

Map<String, dynamic> _expectedOf(Map<String, dynamic> record) =>
    Map<String, dynamic>.from(record['expected'] as Map<String, dynamic>);

Set<String> _namesOf(List<Map<String, dynamic>> records) =>
    records.map((record) => record['name'] as String).toSet();

Future<void> _assertVector(Map<String, dynamic> vector) async {
  final name = vector['name'] as String;
  final date = vector['date'] as String;
  final difficulty = Difficulty.values.byName(vector['difficulty'] as String);
  if (difficulty == Difficulty.challenge) {
    expect(
      DailySeeder(date, Difficulty.challenge).challengeRule.name,
      vector['rule'],
      reason: '$name challenge-rule derivation drifted',
    );
  }

  final cubit = GameCubit(
    storage: InMemoryStorageService(),
    todayProvider: () => date,
  );
  await cubit.init(difficulty: difficulty);

  final rawLog = vector['moveLog'] as List<dynamic>;
  for (final rawEvent in rawLog) {
    final event = MoveEvent.fromJson(
      Map<String, dynamic>.from(rawEvent as Map<String, dynamic>),
    );
    final before = _boardOf(cubit);
    final beforeLength = before.moveLog.length;
    switch (event) {
      case ChainEvent():
        expect(cubit.state, isA<GamePlaying>(), reason: name);
        await cubit.playChain(event.path);
      case ContinueEvent():
        expect(cubit.canOfferAd, isTrue, reason: name);
        await cubit.grantAdReward();
      case MergeEvent():
        fail('$name contains a legacy MergeEvent in an honest vector');
    }
    final after = _boardOf(cubit);
    expect(after.moveLog.length, beforeLength + 1, reason: name);
    expect(after.moveLog.last, event, reason: name);
  }

  final expected = _expectedOf(vector);
  final board = _boardOf(cubit);
  expect(expected['valid'], isTrue, reason: name);
  expect(board.score, expected['score'], reason: name);
  expect(board.highestTier, expected['highestTier'], reason: name);
  expect(board.status.name, expected['status'], reason: name);
  await cubit.close();
}

Future<void> _generateFixture({required bool force}) async {
  final standardRuns = <Difficulty, _ScriptedRun>{};
  for (final difficulty in const [
    Difficulty.easy,
    Difficulty.medium,
    Difficulty.hard,
    Difficulty.legendary,
  ]) {
    standardRuns[difficulty] = await _driveRun(_baseDate, difficulty);
  }

  final challengeRuns = <ChallengeRule, _ScriptedRun>{};
  final missing = <String>[];
  for (final rule in ChallengeRule.values) {
    _ScriptedRun? qualifying;
    for (var offset = 0; offset < _maxDateSearchDays; offset++) {
      final date = _dateAtOffset(offset);
      if (DailySeeder(date, Difficulty.challenge).challengeRule != rule) {
        continue;
      }
      final candidate = await _driveRun(date, Difficulty.challenge);
      // The frozen TS seeder still re-rolls until it sees a same-tier pair,
      // while Dart also accepts ascend-by-one pairs. Qualify dates where both
      // stop on the same initial placement without changing production code.
      if (!_hasAdjacentSameTier(candidate.boardsAfterPrefix.first)) continue;
      final distinguishes = rule != ChallengeRule.comboRush &&
              rule != ChallengeRule.longChainsOnly ||
          candidate.events
              .whereType<ChainEvent>()
              .any((event) => event.path.length >= 3);
      if (distinguishes) {
        qualifying = candidate;
        break;
      }
    }
    if (qualifying == null) {
      missing.add('challenge-${rule.name}');
    } else {
      challengeRuns[rule] = qualifying;
    }
  }

  final allContinues = await _findAllContinuesRun();
  if (allContinues == null) {
    missing.add('standard-all-three-continues');
  }
  final noContinues = standardRuns[Difficulty.medium]!;
  if (noContinues.board.status != GameStatus.outOfMoves ||
      noContinues.board.movesMade != kMovesPerDay ||
      noContinues.board.adContinuesUsed != 0) {
    missing.add('standard-no-continues');
  }
  if (missing.isNotEmpty) {
    throw StateError(
      'Missing required golden-vector scenarios: ${missing.join(', ')}',
    );
  }

  final completeAllContinues = allContinues!;
  expect(completeAllContinues.board.status, GameStatus.outOfMoves);
  expect(completeAllContinues.board.movesMade,
      kMovesPerDay + kAdMoveReward * kMaxAdContinuesPerDay);
  expect(completeAllContinues.board.adContinuesUsed, kMaxAdContinuesPerDay);
  expect(GameEngine.hasMergeAvailable(completeAllContinues.board), isTrue);

  final budgetCut = challengeRuns[ChallengeRule.budgetCut]!;
  expect(budgetCut.board.status, GameStatus.outOfMoves);
  expect(budgetCut.board.movesMade, kChallengeMoves);
  final nonBudget = challengeRuns[ChallengeRule.denseStart]!;
  expect(nonBudget.board.status, GameStatus.outOfMoves);
  expect(nonBudget.board.movesMade, kMovesPerDay);

  final vectors = <Map<String, dynamic>>[
    for (final difficulty in const [
      Difficulty.easy,
      Difficulty.medium,
      Difficulty.hard,
      Difficulty.legendary,
    ])
      standardRuns[difficulty]!.toFixture('standard-${difficulty.name}'),
    for (final rule in ChallengeRule.values)
      challengeRuns[rule]!.toFixture('challenge-${rule.name}'),
    completeAllContinues.toFixture('standard-all-three-continues'),
    noContinues.toFixture('standard-no-continues'),
  ];

  final standardPostBudgetPath = _requiredLegalChain(
      noContinues.board, 2, 'standard post-budget sentinel');
  final budgetPostBudgetPath =
      _requiredLegalChain(budgetCut.board, 2, 'budgetCut post-budget sentinel');
  final nonBudgetPostBudgetPath = _requiredLegalChain(
      nonBudget.board, 2, 'non-budget challenge post-budget sentinel');

  final longChainsOnly = challengeRuns[ChallengeRule.longChainsOnly]!;
  final longSentinel = _findPrefixWithLegalChain(
    longChainsOnly,
    chainLength: 2,
    minimumPrefixLength: 1,
  );
  expect(longSentinel, isNotNull,
      reason: 'longChainsOnly needs a playing prefix with a legal 2-chain');

  final legacySource = standardRuns[Difficulty.easy]!;
  final legacySentinel = _findPrefixWithLegalChain(
    legacySource,
    chainLength: 2,
    minimumPrefixLength: 1,
  );
  expect(legacySentinel, isNotNull,
      reason: 'legacy merge needs a mid-run playing board and legal pair');
  final legacyPath = legacySentinel!.chain;
  expect(
    GameEngine.canMerge(
        legacySentinel.board, legacyPath.first, legacyPath.last),
    isTrue,
  );

  final rejections = <Map<String, dynamic>>[
    _rejection(
      'reject-fourth-continue',
      completeAllContinues,
      [...completeAllContinues.events, const ContinueEvent()],
    ),
    _rejection(
      'reject-standard-post-budget-chain',
      noContinues,
      [...noContinues.events, ChainEvent(path: standardPostBudgetPath)],
    ),
    _rejection(
      'reject-budgetCut-post-budget-chain',
      budgetCut,
      [...budgetCut.events, ChainEvent(path: budgetPostBudgetPath)],
    ),
    _rejection(
      'reject-non-budget-challenge-post-budget-chain',
      nonBudget,
      [...nonBudget.events, ChainEvent(path: nonBudgetPostBudgetPath)],
    ),
    _rejection(
      'reject-longChainsOnly-two-chain',
      longChainsOnly,
      [
        ...longChainsOnly.events.take(longSentinel!.prefixLength),
        ChainEvent(path: longSentinel.chain),
      ],
    ),
    _rejection(
      'reject-legacy-merge-event',
      legacySource,
      [
        ...legacySource.events.take(legacySentinel.prefixLength),
        MergeEvent(from: legacyPath.first, to: legacyPath.last),
      ],
    ),
  ];

  expect(_namesOf(vectors), _requiredVectorNames);
  expect(_namesOf(rejections), _requiredRejectionNames);

  final semanticPayload = <String, dynamic>{
    'vectors': vectors,
    'rejections': rejections,
  };
  final file = File(_fixturePath);
  if (file.existsSync()) {
    final committed = _readFixture();
    final committedSemantic = <String, dynamic>{
      'vectors': committed['vectors'],
      'rejections': committed['rejections'],
    };
    final changed =
        jsonEncode(committedSemantic) != jsonEncode(semanticPayload);
    if (changed && committed['season'] == kLeaderboardSeason && !force) {
      throw StateError(
        'Golden-vector rules changed without a season bump. Bump '
        'kLeaderboardSeason in BOTH constants files, or set '
        'UPDATE_GOLDENS_FORCE=1 if this is a policy-only regeneration.',
      );
    }
  }

  final fixture = <String, dynamic>{
    '_readme': 'Regenerate ONLY for an intentional rule change, in the same '
        'commit as the kLeaderboardSeason bump in both Dart and TypeScript. '
        'Use UPDATE_GOLDENS_FORCE=1 only for a policy-only regeneration.',
    'season': kLeaderboardSeason,
    'baseDate': _baseDate,
    ...semanticPayload,
  };
  file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(fixture)}\n');
}

Future<_ScriptedRun?> _findAllContinuesRun() async {
  for (var offset = 0; offset < _maxDateSearchDays; offset++) {
    final run = await _driveRun(
      _dateAtOffset(offset),
      Difficulty.easy,
      takeContinues: true,
    );
    if (run.board.status == GameStatus.outOfMoves &&
        run.board.movesMade ==
            kMovesPerDay + kAdMoveReward * kMaxAdContinuesPerDay &&
        run.board.adContinuesUsed == kMaxAdContinuesPerDay &&
        GameEngine.hasMergeAvailable(run.board)) {
      return run;
    }
  }
  return null;
}

String _dateAtOffset(int offset) => formatDate(
      DateTime.parse(_baseDate).add(Duration(days: offset)),
    );

Future<_ScriptedRun> _driveRun(
  String date,
  Difficulty difficulty, {
  bool takeContinues = false,
}) async {
  final cubit = GameCubit(
    storage: InMemoryStorageService(),
    todayProvider: () => date,
  );
  await cubit.init(difficulty: difficulty);
  final rule = cubit.activeRule;
  final events = <MoveEvent>[];
  final boardsAfterPrefix = <BoardState>[_boardOf(cubit)];

  for (var eventCount = 0; eventCount < _maxScriptedEvents; eventCount++) {
    final state = cubit.state;
    if (state is GamePlaying) {
      final chainLength = rule == ChallengeRule.longChainsOnly ||
              rule == ChallengeRule.comboRush
          ? 3
          : 2;
      final chain = _firstLegalChain(state.board, chainLength);
      if (chain == null) break;
      final beforeLength = state.board.moveLog.length;
      await cubit.playChain(chain);
      final after = _boardOf(cubit);
      expect(after.moveLog.length, beforeLength + 1,
          reason: '$date:${difficulty.name} rejected scripted chain $chain');
      events.add(ChainEvent(path: chain));
      boardsAfterPrefix.add(after);
      continue;
    }
    if (state is GameOverShowScore && takeContinues && cubit.canOfferAd) {
      await cubit.grantAdReward();
      events.add(const ContinueEvent());
      boardsAfterPrefix.add(_boardOf(cubit));
      continue;
    }
    break;
  }

  if (events.length == _maxScriptedEvents) {
    throw StateError(
        'Scripted run exceeded $_maxScriptedEvents events: $date:${difficulty.name}');
  }
  final board = _boardOf(cubit);
  expect(board.moveLog, events);
  await cubit.close();
  return _ScriptedRun(
    date: date,
    difficulty: difficulty,
    rule: rule,
    events: events,
    boardsAfterPrefix: boardsAfterPrefix,
    board: board,
  );
}

BoardState _boardOf(GameCubit cubit) => switch (cubit.state) {
      GamePlaying(:final board) => board,
      GameOverShowScore(:final board) => board,
      GameAdRewardGranted(:final board) => board,
      GameInitial() => throw StateError('GameCubit was not initialized'),
    };

List<int>? _firstLegalChain(BoardState board, int length) {
  var attempts = 0;

  List<int>? search(List<int> path) {
    if (path.length == length) {
      attempts++;
      if (attempts > _maxChainSearchAttempts) {
        throw StateError(
          'Chain search exceeded $_maxChainSearchAttempts candidates',
        );
      }
      return GameEngine.isValidChain(board, path) ? List<int>.of(path) : null;
    }
    for (var candidate = 0; candidate < board.cells.length; candidate++) {
      if (path.contains(candidate) ||
          board.cells[candidate] == null ||
          board.walls.contains(candidate) ||
          !GameEngine.areOrthogonallyAdjacent(
              path.last, candidate, board.gridSize)) {
        continue;
      }
      final found = search([...path, candidate]);
      if (found != null) return found;
    }
    return null;
  }

  for (var start = 0; start < board.cells.length; start++) {
    if (board.cells[start] == null || board.walls.contains(start)) continue;
    final found = search([start]);
    if (found != null) return found;
  }
  return null;
}

bool _hasAdjacentSameTier(BoardState board) {
  for (var i = 0; i < board.cells.length; i++) {
    final tile = board.cells[i];
    if (tile == null) continue;
    for (var candidate = i + 1; candidate < board.cells.length; candidate++) {
      final other = board.cells[candidate];
      if (other != null &&
          other.tier == tile.tier &&
          GameEngine.areOrthogonallyAdjacent(i, candidate, board.gridSize)) {
        return true;
      }
    }
  }
  return false;
}

List<int> _requiredLegalChain(
  BoardState board,
  int length,
  String sentinel,
) {
  expect(board.status, GameStatus.outOfMoves, reason: sentinel);
  final chain = _firstLegalChain(board, length);
  expect(chain, isNotNull, reason: '$sentinel needs legal geometry');
  expect(GameEngine.isValidChain(board, chain!), isTrue, reason: sentinel);
  return chain;
}

_PrefixSentinel? _findPrefixWithLegalChain(
  _ScriptedRun run, {
  required int chainLength,
  required int minimumPrefixLength,
}) {
  for (var prefix = minimumPrefixLength;
      prefix < run.boardsAfterPrefix.length;
      prefix++) {
    final board = run.boardsAfterPrefix[prefix];
    if (board.status != GameStatus.playing) continue;
    final chain = _firstLegalChain(board, chainLength);
    if (chain != null && GameEngine.isValidChain(board, chain)) {
      return _PrefixSentinel(prefix, board, chain);
    }
  }
  return null;
}

Map<String, dynamic> _rejection(
  String name,
  _ScriptedRun source,
  List<MoveEvent> moveLog,
) =>
    <String, dynamic>{
      'name': name,
      'date': source.date,
      'difficulty': source.difficulty.name,
      if (source.rule != null) 'rule': source.rule!.name,
      'moveLog': moveLog.map((event) => event.toJson()).toList(),
      'expected': <String, dynamic>{'valid': false},
    };

class _ScriptedRun {
  const _ScriptedRun({
    required this.date,
    required this.difficulty,
    required this.rule,
    required this.events,
    required this.boardsAfterPrefix,
    required this.board,
  });

  final String date;
  final Difficulty difficulty;
  final ChallengeRule? rule;
  final List<MoveEvent> events;
  final List<BoardState> boardsAfterPrefix;
  final BoardState board;

  Map<String, dynamic> toFixture(String name) => <String, dynamic>{
        'name': name,
        'date': date,
        'difficulty': difficulty.name,
        if (rule != null) 'rule': rule!.name,
        'moveLog': events.map((event) => event.toJson()).toList(),
        'expected': <String, dynamic>{
          'valid': true,
          'score': board.score,
          'highestTier': board.highestTier,
          'status': board.status.name,
        },
      };
}

class _PrefixSentinel {
  const _PrefixSentinel(this.prefixLength, this.board, this.chain);

  final int prefixLength;
  final BoardState board;
  final List<int> chain;
}
