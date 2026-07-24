import 'dart:async';

import 'package:app_links/app_links.dart';

import '../domain/models/duel_challenge.dart';

final RegExp _friendCodePattern = RegExp(r'^[A-Z2-7]{8}$');
typedef InitialLinkLoader = Future<Uri?> Function();

/// Parses invite + duel deep links and bridges them to redeem/challenge
/// callbacks.
///
/// Supported forms:
///   connectmerge://invite/<code>           (custom scheme)
///   https://www.connectmerge.app/invite/<code>  (App Links fallback)
///   `connectmerge://duel/<date>/<diff>/<score>/<name>`            (custom scheme)
///   `https://www.connectmerge.app/duel/<date>/<diff>/<score>/<name>` (https fallback)
///
/// The PURE parts — [parseInviteCode] and [DuelChallenge.fromUri] — are fully
/// unit-tested. The app_links wiring (cold-start `getInitialLink` + warm
/// `uriLinkStream`) is isolated here so it can be swapped/mocked. Per the spec
/// Invite delivery is wired to the durable redeem coordinator before [init].
/// Duels parsed before the UI is ready remain queued in [pendingDuel].
class DeepLinkService {
  final InitialLinkLoader _getInitialLink;
  final Stream<Uri> _linkStream;

  /// Called with a parsed invite code. May be invoked from cold start (initial
  /// link) and from warm resume (stream). Production wires this before [init].
  void Function(String code)? onInviteCode;

  /// Called with a parsed duel challenge. May be invoked from cold start
  /// (initial link) and from warm resume (stream). If null at parse time, the
  /// challenge is queued in [pendingDuel] for later replay (mirrors invites).
  void Function(DuelChallenge duel)? onDuel;

  /// A duel captured before [onDuel] was wired (cold start). The app consumes
  /// this via [takePendingDuel] once it's ready to present the challenge.
  DuelChallenge? _pendingDuel;
  StreamSubscription<Uri>? _sub;

  factory DeepLinkService({
    AppLinks? appLinks,
    InitialLinkLoader? getInitialLink,
    Stream<Uri>? linkStream,
  }) {
    final links = appLinks ?? AppLinks();
    return DeepLinkService._(
      getInitialLink ?? links.getInitialLink,
      linkStream ?? links.uriLinkStream,
    );
  }

  DeepLinkService._(this._getInitialLink, this._linkStream);

  /// The queued cold-start duel, if any (without clearing it).
  DuelChallenge? get pendingDuel => _pendingDuel;

  /// Pure parser: extract the invite code from a deep-link [uri], or null if it
  /// isn't an invite link. Accepts both the custom scheme and the https path.
  static String? parseInviteCode(Uri uri) {
    if (uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.authority != uri.host ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      return null;
    }
    // connectmerge://invite/<code>  → host == 'invite', first path segment is code.
    if (uri.scheme == 'connectmerge') {
      if (uri.host != 'invite' || uri.pathSegments.length != 1) return null;
      final code = uri.pathSegments.single;
      return uri.toString() == 'connectmerge://invite/$code' &&
              _friendCodePattern.hasMatch(code)
          ? code
          : null;
    }
    // https://<host>/invite/<code>
    if (uri.scheme != 'https' ||
        uri.host != 'www.connectmerge.app' ||
        uri.pathSegments.length != 2 ||
        uri.pathSegments.first != 'invite') {
      return null;
    }
    final code = uri.pathSegments.last;
    return uri.toString() ==
                'https://www.connectmerge.app/invite/$code' &&
            _friendCodePattern.hasMatch(code)
        ? code
        : null;
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
      final initial = await _getInitialLink();
      if (initial != null) _handle(initial);
    } catch (_) {
      // No initial link / platform not ready — ignore.
    }
    _sub = _linkStream.listen(_handle, onError: (_) {});
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
    cb?.call(code);
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
