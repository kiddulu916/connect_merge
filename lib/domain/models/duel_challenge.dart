import 'difficulty.dart';

/// An async 1v1 duel challenge that travels entirely *in a deep link*.
///
/// Because every player on a given `(date, difficulty)` plays the byte-identical
/// seeded board, a challenge is settled honestly by simply replaying the same
/// board — no backend is needed ($0 pillar). The challenger's score + name are
/// carried purely for DISPLAY: they are NEVER authoritative for ranking. Ranking
/// always flows through the verified leaderboard, so a hand-edited (forged) link
/// can only change what the recipient *sees* as the target, never any
/// leaderboard row.
///
/// Link forms (mirrors [DeepLinkService] invite handling):
///   `mergecount://duel/<date>/<diff>/<score>/<name>`
///   `https://mergecount.app/duel/<date>/<diff>/<score>/<name>`
///
/// The trailing `<name>` segment is percent-encoded so unicode and `/` survive
/// the round-trip intact.
class DuelChallenge {
  /// UTC date (`YYYY-MM-DD`) of the challenged board.
  final String date;

  /// Tier of the challenged board.
  final Difficulty difficulty;

  /// The challenger's display name (display-only).
  final String challengerName;

  /// The challenger's CLAIMED score (display-only, never authoritative).
  final int challengerScore;

  const DuelChallenge({
    required this.date,
    required this.difficulty,
    required this.challengerName,
    required this.challengerScore,
  });

  /// The https host used for the App Links / Universal Links fallback form.
  static const String _httpsHost = 'mergecount.app';

  /// Encode this challenge as a custom-scheme deep link.
  Uri toUri() => Uri.parse(
        'connectmerge://duel/$date/${difficulty.name}/$challengerScore/'
        '${Uri.encodeComponent(challengerName)}',
      );

  /// Encode this challenge as the https fallback deep link.
  Uri toHttpsUri() => Uri.parse(
        'https://$_httpsHost/duel/$date/${difficulty.name}/$challengerScore/'
        '${Uri.encodeComponent(challengerName)}',
      );

  /// Pure parser: decode a duel challenge from a deep-link [uri], or null when
  /// the link is not a (well-formed) duel link. Accepts both the custom scheme
  /// and the https path. Malformed/legacy/invite links return null so duel
  /// parsing coexists with invite parsing.
  static DuelChallenge? fromUri(Uri uri) {
    List<String> segs;
    if (uri.scheme == 'connectmerge') {
      if (uri.host != 'duel') return null;
      segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    } else if (uri.scheme == 'https' || uri.scheme == 'http') {
      final all = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (all.isEmpty || all.first != 'duel') return null;
      segs = all.sublist(1);
    } else {
      return null;
    }
    // Expect: <date>/<diff>/<score>/<name>
    if (segs.length < 4) return null;
    final date = segs[0];
    if (!_isValidDate(date)) return null;
    final diff = Difficulty.values.asNameMap()[segs[1]];
    if (diff == null) return null;
    final score = int.tryParse(segs[2]);
    if (score == null || score < 0) return null;
    // [Uri.pathSegments] are ALREADY percent-decoded. `toUri` encodes the name
    // with [Uri.encodeComponent] (which also encodes '/'), so a well-formed link
    // keeps the whole name in a single decoded segment. We still rejoin any
    // trailing segments with '/' to tolerate a name that contained a raw,
    // unencoded slash — no second decode (that would corrupt literal '%').
    final name = segs.sublist(3).join('/');
    if (name.isEmpty) return null;
    return DuelChallenge(
      date: date,
      difficulty: diff,
      challengerName: name,
      challengerScore: score,
    );
  }

  /// Parse a raw link string; null when it's not a valid duel link.
  static DuelChallenge? fromString(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null) return null;
    return fromUri(uri);
  }

  static bool _isValidDate(String s) {
    // Strict YYYY-MM-DD shape (the seed/storage key format).
    final re = RegExp(r'^\d{4}-\d{2}-\d{2}$');
    return re.hasMatch(s);
  }

  @override
  bool operator ==(Object other) =>
      other is DuelChallenge &&
      other.date == date &&
      other.difficulty == difficulty &&
      other.challengerName == challengerName &&
      other.challengerScore == challengerScore;

  @override
  int get hashCode =>
      Object.hash(date, difficulty, challengerName, challengerScore);

  @override
  String toString() =>
      'DuelChallenge(date: $date, difficulty: ${difficulty.name}, '
      'challengerName: $challengerName, challengerScore: $challengerScore)';
}

/// The outcome of comparing the recipient's score against a duel challenge.
enum DuelOutcome { win, lose, tie }
