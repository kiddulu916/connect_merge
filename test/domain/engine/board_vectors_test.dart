import 'dart:convert';
import 'dart:io';

import 'package:connect_merge/application/game_cubit.dart';
import 'package:connect_merge/application/game_state.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/engine/daily_seeder.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/challenge_rule.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/tile.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const _fixturePath = 'supabase/functions/_shared/board_vectors.json';
const _epoch = '2026-07-14';
const _days = 365;
const _difficulties = <Difficulty>[
  Difficulty.easy,
  Difficulty.medium,
  Difficulty.hard,
  Difficulty.legendary,
  Difficulty.challenge,
];

void main() {
  test('Dart board generation matches the committed board-parity digests',
      () async {
    if (Platform.environment['UPDATE_GOLDENS'] == '1') {
      await _generateFixture();
    }

    final fixture =
        jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>;
    expect(fixture['epoch'], _epoch);
    expect(fixture['days'], _days);

    final entries = (fixture['entries'] as List<dynamic>)
        .map((e) => Map<String, dynamic>.from(e as Map<String, dynamic>))
        .toList();
    expect(entries.length, _days * _difficulties.length);

    for (final entry in entries) {
      final date = entry['date'] as String;
      final difficulty =
          Difficulty.values.byName(entry['difficulty'] as String);
      final digest = await _digestFor(date, difficulty);
      expect(digest, entry['digest'],
          reason: 'board digest drift at $date ${difficulty.name}');
    }
  });
}

String _dateAtOffset(int offset) {
  final d = DateTime.utc(2026, 7, 14).add(Duration(days: offset));
  final mm = d.month.toString().padLeft(2, '0');
  final dd = d.day.toString().padLeft(2, '0');
  return '${d.year}-$mm-$dd';
}

Future<String> _digestFor(String date, Difficulty difficulty) async {
  final seeder = DailySeeder(date, difficulty);
  final BoardState board;
  final String rule;
  final int mcl;
  if (difficulty == Difficulty.challenge) {
    final cubit = GameCubit(
      storage: InMemoryStorageService(),
      todayProvider: () => date,
    );
    await cubit.init(difficulty: Difficulty.challenge);
    board = (cubit.state as GamePlaying).board;
    rule = seeder.challengeRule.name;
    mcl = seeder.challengeRule.minChainLength;
  } else {
    board = seeder.generate().board;
    rule = '-';
    mcl = 2;
  }
  return _digest(_canonical(board, _dropSchedule(seeder), rule, mcl));
}

List<int> _dropSchedule(DailySeeder seeder) {
  final p = seeder.dropTierPrng();
  return [for (var n = 0; n < kMaxDrops; n++) seeder.dropTierAt(p, n)];
}

String _canonical(BoardState board, List<int> drops, String rule, int mcl) {
  final cells = [
    for (final Tile? t in board.cells) t == null ? 'x' : '${t.tier}',
  ].join(',');
  final walls = (board.walls.toList()..sort()).join(',');
  return 'g=${board.gridSize};m=${board.movesRemaining};cells=$cells;'
      'walls=$walls;drops=${drops.join(',')};rule=$rule;mcl=$mcl';
}

String _digest(String canonical) =>
    sha256.convert(utf8.encode(canonical)).toString();

Future<void> _generateFixture() async {
  final entries = <Map<String, dynamic>>[];
  for (var offset = 0; offset < _days; offset++) {
    final date = _dateAtOffset(offset);
    for (final difficulty in _difficulties) {
      entries.add(<String, dynamic>{
        'date': date,
        'difficulty': difficulty.name,
        'digest': await _digestFor(date, difficulty),
      });
    }
  }
  final fixture = <String, dynamic>{
    '_readme':
        'Board-generation parity digests (Dart<->TS). Regenerate with '
            'UPDATE_GOLDENS=1 alongside any change to DailySeeder generation or '
            'challenge overrides. No season: board digests never touch the '
            'leaderboard.',
    'epoch': _epoch,
    'days': _days,
    'entries': entries,
  };
  File(_fixturePath).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(fixture)}\n');
}
