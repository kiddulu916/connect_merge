import 'dart:async';

import 'package:app_links/app_links.dart';

import '../domain/models/duel_challenge.dart';

/// Parses invite + duel deep links and bridges them to redeem/challenge
/// callbacks.
///
/// Supported forms:
///   connectmerge://invite/<code>           (custom scheme)
///   https://connectmerge.app/invite/<code>  (App Links / Universal Links fallback)
///   `connectmerge://duel/<date>/<diff>/<score>/<name>`            (custom scheme)
///   `https://connectmerge.app/duel/<date>/<diff>/<score>/<name>`   (https fallback)
///
/// The PURE parts — [parseInviteCode] and [DuelChallenge.fromUri] — are fully
/// unit-tested. The app_links wiring (cold-start `getInitialLink` + warm
/// `uriLinkStream`) is isolated here so it can be swapped/mocked. Per the spec
/// failure-mode "lost on cold start": an invite code or duel parsed before the
/// app is ready is QUEUED ([pendingCode] / [pendingDuel]) and replayed by the
/// app once it's ready.
class DeepLinkService {
  final AppLinks _appLinks;

  /// Called with a parsed invite code. May be invoked from cold start (initial
  /// link) and from warm resume (stream). If null at parse time, the code is
  /// queued in [pendingCode] for later replay.
  void Function(String code)? onInviteCode;

  /// Called with a parsed duel challenge. May be invoked from cold start
  /// (initial link) and from warm resume (stream). If null at parse time, the
  /// challenge is queued in [pendingDuel] for later replay (mirrors invites).
  void Function(DuelChallenge duel)? onDuel;

  /// A code captured before [onInviteCode] was wired (cold start before auth).
  /// The app consumes this via [takePendingCode] once it's ready to redeem.
  String? _pendingCode;

  /// A duel captured before [onDuel] was wired (cold start). The app consumes
  /// this via [takePendingDuel] once it's ready to present the challenge.
  DuelChallenge? _pendingDuel;
  StreamSubscription<Uri>? _sub;

  DeepLinkService({AppLinks? appLinks}) : _appLinks = appLinks ?? AppLinks();

  /// The queued cold-start code, if any (without clearing it).
  String? get pendingCode => _pendingCode;

  /// The queued cold-start duel, if any (without clearing it).
  DuelChallenge? get pendingDuel => _pendingDuel;

  /// Pure parser: extract the invite code from a deep-link [uri], or null if it
  /// isn't an invite link. Accepts both the custom scheme and the https path.
  static String? parseInviteCode(Uri uri) {
    // connectmerge://invite/<code>  → host == 'invite', first path segment is code.
    if (uri.scheme == 'connectmerge') {
      if (uri.host == 'invite') {
        final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
        if (segs.isNotEmpty) return segs.first;
      }
      return null;
    }
    // https://<host>/invite/<code>
    if (uri.scheme == 'https' || uri.scheme == 'http') {
      final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segs.length >= 2 && segs[0] == 'invite') return segs[1];
      return null;
    }
    return null;
  }

  /// Parse a raw link string; null when it's not an invite link or unparsable.
  static String? parseInviteCodeString(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null) return null;
    return parseInviteCode(uri);
  }

  /// Pure parser: extract a [DuelChallenge] from a deep-link [uri], or null if it
  /// isn't a (well-formed) duel link. Delegates to [DuelChallenge.fromUri] so the
  /// encode/decode round-trip is owned by the model.
  static DuelChallenge? parseDuel(Uri uri) => DuelChallenge.fromUri(uri);

  /// Parse a raw link string as a duel; null when it's not a valid duel link.
  static DuelChallenge? parseDuelString(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null) return null;
    return DuelChallenge.fromUri(uri);
  }

  /// Start listening: handle the cold-start link then subscribe to warm links.
  /// Safe to call once after the app boots.
  Future<void> init() async {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) _handle(initial);
    } catch (_) {
      // No initial link / platform not ready — ignore.
    }
    _sub = _appLinks.uriLinkStream.listen(_handle, onError: (_) {});
  }

  void _handle(Uri uri) {
    // Duel links take precedence on the duel host/path; invite links on theirs.
    // They never overlap (distinct hosts/first segments) so order is harmless.
    final duel = parseDuel(uri);
    if (duel != null) {
      final cb = onDuel;
      if (cb != null) {
        cb(duel);
      } else {
        _pendingDuel = duel; // queue for replay once the app is ready.
      }
      return;
    }
    final code = parseInviteCode(uri);
    if (code == null) return;
    final cb = onInviteCode;
    if (cb != null) {
      cb(code);
    } else {
      _pendingCode = code; // queue for replay once the app is ready.
    }
  }

  /// Consume and clear the queued cold-start code (returns null if none).
  String? takePendingCode() {
    final c = _pendingCode;
    _pendingCode = null;
    return c;
  }

  /// Consume and clear the queued cold-start duel (returns null if none).
  DuelChallenge? takePendingDuel() {
    final d = _pendingDuel;
    _pendingDuel = null;
    return d;
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }
}
