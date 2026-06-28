import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/models/day_result.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/infrastructure/hive_storage_service.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';

DayResult result(String date,
        {Difficulty difficulty = Difficulty.medium,
        int score = 100,
        int highestTier = 5,
        bool endedOutOfMoves = true}) =>
    DayResult(
      date: date,
      difficulty: difficulty,
      score: score,
      highestTier: highestTier,
      endedOutOfMoves: endedOutOfMoves,
    );

void main() {
  group('DayResult model', () {
    test('round-trips through json (incl. difficulty by name)', () {
      final r = result('2026-06-07',
          difficulty: Difficulty.legendary,
          score: 4096,
          highestTier: 11,
          endedOutOfMoves: false);
      final decoded = DayResult.fromJson(r.toJson());
      expect(decoded, r);
      expect(decoded.difficulty, Difficulty.legendary);
      expect(decoded.endedOutOfMoves, isFalse);
    });

    test('legacy `win` json key still decodes into endedOutOfMoves '
        '(migration-free)', () {
      // A record written before the rename carried `win` with the same fact.
      final legacy = {
        'date': '2026-06-07',
        'difficulty': 'hard',
        'score': 256,
        'highestTier': 8,
        'win': false,
      };
      final decoded = DayResult.fromJson(legacy);
      expect(decoded.endedOutOfMoves, isFalse);
      expect(decoded.difficulty, Difficulty.hard);
      expect(decoded.score, 256);

      // And a legacy true value decodes to true.
      final legacyTrue = Map<String, dynamic>.from(legacy)..['win'] = true;
      expect(DayResult.fromJson(legacyTrue).endedOutOfMoves, isTrue);
    });

    test('value equality', () {
      expect(result('2026-06-07'), result('2026-06-07'));
      expect(result('2026-06-07'),
          isNot(result('2026-06-07', score: 999)));
    });
  });

  group('InMemory history log', () {
    late InMemoryStorageService s;
    setUp(() async {
      s = InMemoryStorageService();
      await s.init();
    });

    test('empty by default (migration-free for pre-Phase-4 players)', () {
      expect(s.loadHistory(), isEmpty);
    });

    test('append then read in chronological (insertion) order', () async {
      await s.appendResult(result('2026-06-05', score: 1));
      await s.appendResult(result('2026-06-06', score: 2));
      await s.appendResult(result('2026-06-07', score: 3));
      final h = s.loadHistory();
      expect(h.map((r) => r.score).toList(), [1, 2, 3]);
    });

    test('caps at kHistoryRetentionDays, dropping the oldest', () async {
      // Append a few past the cap.
      for (var i = 0; i < kHistoryRetentionDays + 5; i++) {
        await s.appendResult(result('d$i', score: i));
      }
      final h = s.loadHistory();
      expect(h.length, kHistoryRetentionDays);
      // Oldest five were dropped; the newest is last.
      expect(h.first.score, 5);
      expect(h.last.score, kHistoryRetentionDays + 4);
    });
  });

  group('Hive history log (persisted)', () {
    setUp(() {
      Hive.init(
          '${Directory.systemTemp.path}/merge_count_hist_${DateTime.now().microsecondsSinceEpoch}');
    });
    tearDown(() async {
      await Hive.deleteFromDisk();
    });

    test('absent history loads as empty (migration-free)', () async {
      final s = HiveStorageService();
      await s.init();
      expect(s.loadHistory(), isEmpty);
    });

    test('append persists and reloads across instances', () async {
      final s1 = HiveStorageService();
      await s1.init();
      await s1.appendResult(result('2026-06-06',
          difficulty: Difficulty.hard, score: 256, highestTier: 8));
      await s1.appendResult(result('2026-06-07',
          difficulty: Difficulty.easy,
          score: 64,
          highestTier: 6,
          endedOutOfMoves: false));

      // A fresh instance reads the same persisted box.
      final s2 = HiveStorageService();
      await s2.init();
      final h = s2.loadHistory();
      expect(h.length, 2);
      expect(h[0].difficulty, Difficulty.hard);
      expect(h[0].score, 256);
      expect(h[1].difficulty, Difficulty.easy);
      expect(h[1].endedOutOfMoves, isFalse);
    });

    test('caps at kHistoryRetentionDays via Hive', () async {
      final s = HiveStorageService();
      await s.init();
      for (var i = 0; i < kHistoryRetentionDays + 3; i++) {
        await s.appendResult(result('d$i', score: i));
      }
      final h = s.loadHistory();
      expect(h.length, kHistoryRetentionDays);
      expect(h.first.score, 3); // oldest three dropped
      expect(h.last.score, kHistoryRetentionDays + 2);
    });
  });
}
