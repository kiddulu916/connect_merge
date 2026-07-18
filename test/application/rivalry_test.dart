import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/application/rivalry_cubit.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';

void main() {
  group('RivalryCubit.rivalPassedMe (pure)', () {
    test('rival ahead of me AND ahead of last-seen -> passed', () {
      expect(
        RivalryCubit.rivalPassedMe(
            myScore: 100, rivalScore: 150, lastSeenRivalScore: 120),
        isTrue,
      );
    });

    test('rival ahead of me but NOT ahead of last-seen -> not passed', () {
      // Already reacted to this (or higher) overtake; do not re-fire.
      expect(
        RivalryCubit.rivalPassedMe(
            myScore: 100, rivalScore: 150, lastSeenRivalScore: 150),
        isFalse,
      );
    });

    test('rival behind me -> not passed', () {
      expect(
        RivalryCubit.rivalPassedMe(
            myScore: 200, rivalScore: 150, lastSeenRivalScore: 0),
        isFalse,
      );
    });

    test('tie -> not passed (must strictly exceed)', () {
      expect(
        RivalryCubit.rivalPassedMe(
            myScore: 150, rivalScore: 150, lastSeenRivalScore: 0),
        isFalse,
      );
    });
  });

  group('RivalDelta math', () {
    test('ahead', () {
      const d = RivalDelta(myScore: 200, rivalScore: 150);
      expect(d.delta, 50);
      expect(d.amAhead, isTrue);
      expect(d.amBehind, isFalse);
      expect(d.tied, isFalse);
    });

    test('behind', () {
      const d = RivalDelta(myScore: 100, rivalScore: 150);
      expect(d.delta, -50);
      expect(d.amBehind, isTrue);
    });

    test('tied', () {
      const d = RivalDelta(myScore: 150, rivalScore: 150);
      expect(d.delta, 0);
      expect(d.tied, isTrue);
    });
  });

  group('RivalryCubit set / clear / null rival', () {
    late InMemoryStorageService storage;
    RivalryCubit make() => RivalryCubit(storage: storage)..load();

    setUp(() => storage = InMemoryStorageService());

    test('starts with no rival', () {
      final c = make();
      expect(c.state.hasRival, isFalse);
      expect(c.state.rivalId, isNull);
    });

    test('setRival persists id + name', () async {
      final c = make();
      await c.setRival(rivalId: 'p1', rivalName: 'Ann');
      expect(c.state.hasRival, isTrue);
      expect(c.state.rivalId, 'p1');
      expect(c.state.rivalName, 'Ann');
      expect(storage.loadProfile().rivalry.rivalId, 'p1');
      expect(storage.loadProfile().rivalry.rivalName, 'Ann');
    });

    test('clearRival removes the rival', () async {
      final c = make();
      await c.setRival(rivalId: 'p1', rivalName: 'Ann');
      await c.clearRival();
      expect(c.state.hasRival, isFalse);
      expect(c.state.rivalId, isNull);
      expect(storage.loadProfile().rivalry.rivalId, isNull);
      expect(storage.loadProfile().rivalry.rivalName, isNull);
    });

    test('switching rival clears stale last-seen so no spurious nudge', () async {
      final c = make();
      await c.setRival(rivalId: 'p1', rivalName: 'Ann');
      // Record a high score against the first rival.
      await c.recordRivalScore(
          difficulty: Difficulty.hard, myScore: 10, rivalScore: 999);
      // Switch rivals: last-seen must reset.
      await c.setRival(rivalId: 'p2', rivalName: 'Bob');
      expect(c.state.lastSeenRivalScoreByTier, isEmpty);
    });
  });

  group('RivalryCubit.recordRivalScore once-per-pass', () {
    late InMemoryStorageService storage;
    RivalryCubit make() => RivalryCubit(storage: storage)..load();

    setUp(() => storage = InMemoryStorageService());

    test('a single overtake reports passed exactly once', () async {
      final c = make();
      await c.setRival(rivalId: 'p1', rivalName: 'Ann');

      // First fetch: rival overtakes -> fires.
      final first = await c.recordRivalScore(
          difficulty: Difficulty.hard, myScore: 100, rivalScore: 150);
      expect(first, isTrue);

      // Repeated identical fetch: no change -> does NOT fire again.
      final second = await c.recordRivalScore(
          difficulty: Difficulty.hard, myScore: 100, rivalScore: 150);
      expect(second, isFalse);

      // Even a slightly lower rival score (transient) does not re-arm.
      final third = await c.recordRivalScore(
          difficulty: Difficulty.hard, myScore: 100, rivalScore: 140);
      expect(third, isFalse);
    });

    test('a NEW higher overtake fires again (one per pass)', () async {
      final c = make();
      await c.setRival(rivalId: 'p1', rivalName: 'Ann');

      expect(
        await c.recordRivalScore(
            difficulty: Difficulty.hard, myScore: 100, rivalScore: 150),
        isTrue,
      );
      // I reclaim the lead...
      expect(
        await c.recordRivalScore(
            difficulty: Difficulty.hard, myScore: 300, rivalScore: 150),
        isFalse,
      );
      // ...then the rival passes me AGAIN with a fresh, higher score.
      expect(
        await c.recordRivalScore(
            difficulty: Difficulty.hard, myScore: 300, rivalScore: 320),
        isTrue,
      );
    });

    test('per-tier independence: a pass on hard does not gate easy', () async {
      final c = make();
      await c.setRival(rivalId: 'p1', rivalName: 'Ann');

      expect(
        await c.recordRivalScore(
            difficulty: Difficulty.hard, myScore: 10, rivalScore: 50),
        isTrue,
      );
      // Easy has its own last-seen (0), so a first easy overtake still fires.
      expect(
        await c.recordRivalScore(
            difficulty: Difficulty.easy, myScore: 10, rivalScore: 20),
        isTrue,
      );
    });

    test('records last-seen so it persists across cubit reloads', () async {
      var c = make();
      await c.setRival(rivalId: 'p1', rivalName: 'Ann');
      await c.recordRivalScore(
          difficulty: Difficulty.hard, myScore: 100, rivalScore: 150);

      // Reload from storage: last-seen survives, so no duplicate nudge.
      c = make();
      expect(c.state.lastSeenFor(Difficulty.hard), 150);
      expect(
        await c.recordRivalScore(
            difficulty: Difficulty.hard, myScore: 100, rivalScore: 150),
        isFalse,
      );
    });
  });
}
