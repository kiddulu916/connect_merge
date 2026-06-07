import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:merge_loop/domain/constants.dart';
import 'package:merge_loop/domain/models/board_state.dart';
import 'package:merge_loop/domain/models/game_status.dart';
import 'package:merge_loop/domain/models/tile.dart';
import 'package:merge_loop/infrastructure/hive_storage_service.dart';
import 'package:merge_loop/infrastructure/storage_service.dart';

void main() {
  setUp(() {
    // Use a unique temp dir so each test run is isolated.
    Hive.init('${Directory.systemTemp.path}/merge_loop_test_${DateTime.now().microsecondsSinceEpoch}');
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
  });

  test('persists and reloads a snapshot via Hive', () async {
    final s = HiveStorageService();
    await s.init();

    final board = BoardState(
      cells: List<Tile?>.filled(kCellCount, null),
      movesRemaining: 29,
      score: 16,
      nextTileId: 9,
      dropIndex: 1,
      adContinuesUsed: 0,
      movesMade: 1,
      status: GameStatus.playing,
    );
    await s.saveSnapshot(GameSnapshot(date: '2026-06-06', board: board, completed: false));

    final loaded = s.loadSnapshot()!;
    expect(loaded.date, '2026-06-06');
    expect(loaded.board.score, 16);
    expect(loaded.board.dropIndex, 1);
  });

  test('json encoding is stable', () {
    const stats = LifetimeStats(streak: 1, lastCompletedDate: '2026-06-06', bestScore: 10, bestTier: 3);
    expect(LifetimeStats.fromJson(jsonDecode(jsonEncode(stats.toJson())) as Map<String, dynamic>).bestScore, 10);
  });
}
