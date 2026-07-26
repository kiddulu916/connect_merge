import 'dart:io';

import 'package:play_install_referrer/play_install_referrer.dart';

typedef InstallReferrerAnalytics = void Function(
  String event,
  Map<String, Object?>? parameters,
);

/// Fetches the Android Play install referrer once and hands valid friend codes
/// to the durable redeem coordinator.
class InstallReferrerService {
  final Future<String?> Function() _fetch;
  final bool Function() _isAndroid;
  final bool Function() _isHandled;
  final Future<void> Function() _markHandled;
  final Future<void> Function(String code) _enqueue;
  final InstallReferrerAnalytics? _analytics;

  InstallReferrerService({
    required bool Function() isHandled,
    required Future<void> Function() markHandled,
    required Future<void> Function(String code) enqueue,
    Future<String?> Function()? fetch,
    bool Function()? isAndroid,
    InstallReferrerAnalytics? analytics,
  })  : _fetch = fetch ?? _fetchFromPlay,
        _isAndroid = isAndroid ?? (() => Platform.isAndroid),
        _isHandled = isHandled,
        _markHandled = markHandled,
        _enqueue = enqueue,
        _analytics = analytics;

  static String? parseCode(String? referrer) {
    if (referrer == null || referrer.isEmpty) return null;
    try {
      final code = Uri.splitQueryString(referrer)['code'];
      return code != null && _friendCodePattern.hasMatch(code) ? code : null;
    } catch (_) {
      // Referrer is attacker-settable: any malformed input (bad percent-
      // encoding throws ArgumentError, not just FormatException) → no code.
      return null;
    }
  }

  Future<void> capture() async {
    if (!_isAndroid() || _isHandled()) return;

    String? raw;
    try {
      raw = await _fetch();
      _analytics?.call('referrer_fetch', const {'result': 'success'});
    } catch (error) {
      _analytics?.call('referrer_fetch', {
        'result': 'failure',
        'reason': error.runtimeType.toString(),
      });
      return;
    }

    final code = parseCode(raw);
    if (code == null) {
      await _markHandled();
      return;
    }
    await _enqueue(code);
  }

  static Future<String?> _fetchFromPlay() async {
    final details = await PlayInstallReferrer.installReferrer;
    return details.installReferrer;
  }
}

final RegExp _friendCodePattern = RegExp(r'^[A-Z2-7]{8}$');
