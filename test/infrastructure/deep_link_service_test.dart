import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/duel_challenge.dart';
import 'package:connect_merge/infrastructure/deep_link_service.dart';

void main() {
  group('DeepLinkService.parseInviteCode', () {
    test('parses custom scheme connectmerge://invite/<code>', () {
      expect(
        DeepLinkService.parseInviteCodeString('connectmerge://invite/ABCD2345'),
        'ABCD2345',
      );
    });

    test('parses the exact canonical https form', () {
      expect(
        DeepLinkService.parseInviteCodeString(
            'https://www.connectmerge.app/invite/WXYZ7654'),
        'WXYZ7654',
      );
    });

    test('returns null for non-invite custom-scheme links', () {
      expect(
        DeepLinkService.parseInviteCodeString('connectmerge://other/thing'),
        isNull,
      );
    });

    test('returns null for unrelated https links', () {
      expect(
        DeepLinkService.parseInviteCodeString('https://example.com/foo/bar'),
        isNull,
      );
    });

    test('returns null when code segment is missing', () {
      expect(
          DeepLinkService.parseInviteCodeString('connectmerge://invite/'), isNull);
      expect(DeepLinkService.parseInviteCodeString('connectmerge://invite'),
          isNull);
    });

    test('returns null for garbage', () {
      expect(DeepLinkService.parseInviteCodeString('not a uri at all ::: '),
          isNull);
    });

    test('does NOT mis-parse a duel link as an invite code', () {
      expect(
        DeepLinkService.parseInviteCodeString(
            'connectmerge://duel/2026-06-11/hard/4096/Ann'),
        isNull,
      );
    });

    test('rejects invalid friend codes', () {
      for (final link in [
        'connectmerge://invite/SHORT22',
        'connectmerge://invite/ABC01899',
        'connectmerge://invite/abcd2345',
        'https://www.connectmerge.app/invite/ABC01899',
      ]) {
        expect(DeepLinkService.parseInviteCodeString(link), isNull,
            reason: link);
      }
    });

    test('rejects non-exact custom-scheme forms', () {
      for (final link in [
        'connectmerge://invite/ABCD2345/extra',
        'connectmerge://invite/ABCD2345/',
        'connectmerge://invite/ABCD2345?source=x',
        'connectmerge://invite/ABCD2345#fragment',
        'connectmerge://other/ABCD2345',
      ]) {
        expect(DeepLinkService.parseInviteCodeString(link), isNull,
            reason: link);
      }
    });

    test('rejects non-canonical web forms', () {
      for (final link in [
        'http://www.connectmerge.app/invite/ABCD2345',
        'https://connectmerge.app/invite/ABCD2345',
        'https://evil.example/invite/ABCD2345',
        'https://www.connectmerge.app/invite/ABCD2345/extra',
        'https://www.connectmerge.app/invite/ABCD2345/',
        'https://www.connectmerge.app/invite/ABCD2345?source=x',
        'https://www.connectmerge.app/invite/ABCD2345#fragment',
        'https://www.connectmerge.app/inviteevil/ABCD2345',
      ]) {
        expect(DeepLinkService.parseInviteCodeString(link), isNull,
            reason: link);
      }
    });
  });

  group('DuelChallenge encode/decode round-trip', () {
    final samples = <DuelChallenge>[
      const DuelChallenge(
        date: '2026-06-11',
        difficulty: Difficulty.hard,
        challengerName: 'Ann',
        challengerScore: 4096,
      ),
      const DuelChallenge(
        date: '2026-01-02',
        difficulty: Difficulty.legendary,
        challengerName: 'Zoë 🦊',
        challengerScore: 0,
      ),
      const DuelChallenge(
        date: '2026-12-31',
        difficulty: Difficulty.easy,
        challengerName: 'a/b/c slash name',
        challengerScore: 123456,
      ),
      const DuelChallenge(
        date: '2026-03-04',
        difficulty: Difficulty.medium,
        challengerName: 'プレイヤー',
        challengerScore: 42,
      ),
    ];

    test('custom-scheme fromUri(toUri(x)) == x for many x', () {
      for (final x in samples) {
        expect(DuelChallenge.fromUri(x.toUri()), x, reason: '$x');
        // and via the service entry point
        expect(DeepLinkService.parseDuel(x.toUri()), x, reason: '$x');
      }
    });

    test('https fromUri(toHttpsUri(x)) == x for many x', () {
      for (final x in samples) {
        expect(DuelChallenge.fromUri(x.toHttpsUri()), x, reason: '$x');
      }
    });

    test('a name containing slashes survives the round-trip intact', () {
      const x = DuelChallenge(
        date: '2026-06-11',
        difficulty: Difficulty.hard,
        challengerName: 'one/two/three',
        challengerScore: 7,
      );
      final back = DuelChallenge.fromUri(x.toUri());
      expect(back?.challengerName, 'one/two/three');
    });

    test('a unicode name survives the round-trip intact', () {
      const x = DuelChallenge(
        date: '2026-06-11',
        difficulty: Difficulty.hard,
        challengerName: 'Renée 🎮 玩家',
        challengerScore: 99,
      );
      expect(DuelChallenge.fromUri(x.toUri())?.challengerName, x.challengerName);
    });
  });

  group('DuelChallenge.fromUri malformed / legacy', () {
    test('an invite link is NOT a duel', () {
      expect(
        DeepLinkService.parseDuelString('connectmerge://invite/ABCD2345'),
        isNull,
      );
    });

    test('missing segments return null', () {
      expect(
        DeepLinkService.parseDuelString('connectmerge://duel/2026-06-11/hard'),
        isNull,
      );
    });

    test('bad date shape returns null', () {
      expect(
        DeepLinkService.parseDuelString('connectmerge://duel/yesterday/hard/10/Ann'),
        isNull,
      );
    });

    test('unknown difficulty returns null', () {
      expect(
        DeepLinkService.parseDuelString(
            'connectmerge://duel/2026-06-11/impossible/10/Ann'),
        isNull,
      );
    });

    test('non-numeric / negative score returns null', () {
      expect(
        DeepLinkService.parseDuelString('connectmerge://duel/2026-06-11/hard/x/Ann'),
        isNull,
      );
      expect(
        DeepLinkService.parseDuelString('connectmerge://duel/2026-06-11/hard/-5/Ann'),
        isNull,
      );
    });

    test('garbage returns null', () {
      expect(DeepLinkService.parseDuelString('not a uri ::: '), isNull);
    });
  });

  group('app_links delivery', () {
    test('cold-start invite is delivered through the exact parser', () async {
      final links = StreamController<Uri>.broadcast();
      final received = <String>[];
      final service = DeepLinkService(
        getInitialLink: () async =>
            Uri.parse('https://www.connectmerge.app/invite/ABCD2345'),
        linkStream: links.stream,
      )..onInviteCode = received.add;

      await service.init();
      expect(received, ['ABCD2345']);

      await service.dispose();
      await links.close();
    });

    test('warm invite is delivered and dispose stops the stream', () async {
      final links = StreamController<Uri>.broadcast();
      final received = <String>[];
      final service = DeepLinkService(
        getInitialLink: () async => null,
        linkStream: links.stream,
      )..onInviteCode = received.add;

      await service.init();
      links.add(Uri.parse('connectmerge://invite/WXYZ7654'));
      await Future<void>.delayed(Duration.zero);
      expect(received, ['WXYZ7654']);

      await service.dispose();
      links.add(Uri.parse('connectmerge://invite/ABCD2345'));
      await Future<void>.delayed(Duration.zero);
      expect(received, ['WXYZ7654']);
      await links.close();
    });
  });
}
