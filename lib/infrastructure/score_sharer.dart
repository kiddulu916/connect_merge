import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Shares a rendered PNG of the result card. Two stages so the UI can fall back
/// when Facebook isn't installed.
abstract class ScoreSharer {
  const ScoreSharer();

  /// Hand [pngBytes] to the Facebook app's composer. Returns true if Facebook
  /// handled it, false if it isn't installed (or the platform can't target it).
  Future<bool> shareToFacebook(Uint8List pngBytes);

  /// Fallback: share [pngBytes] via the OS share sheet.
  Future<void> shareToSheet(Uint8List pngBytes);
}

// Production sharer. Tries to open the Facebook app via a platform channel
// (Android ACTION_SEND to com.facebook.katana); falls back to the OS sheet.
class PlatformScoreSharer extends ScoreSharer {
  const PlatformScoreSharer();

  static const MethodChannel _channel =
      MethodChannel('merge_count/facebook_share');

  @override
  Future<bool> shareToFacebook(Uint8List pngBytes) async {
    try {
      final ok = await _channel.invokeMethod<bool>('shareImage', {
        'bytes': pngBytes,
      });
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // Non-Android / channel not registered: let the caller fall back.
      return false;
    }
  }

  @override
  Future<void> shareToSheet(Uint8List pngBytes) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/merge_count_score.png');
    await file.writeAsBytes(pngBytes, flush: true);
    await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], subject: 'Merge Count'));
  }
}
