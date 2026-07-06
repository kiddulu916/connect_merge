import 'package:flutter/services.dart';

/// Thin wrapper around the native Android UMP consent channel.
///
/// On platforms where the channel doesn't exist (iOS, web) every method
/// falls back to a permissive default so ad initialisation is unblocked.
class ConsentService {
  static const _channel = MethodChannel('connect_merge/consent');

  /// Returns true when the UMP SDK says it is safe to request ads.
  /// Defaults to true on non-Android platforms.
  Future<bool> canRequestAds() async {
    try {
      return await _channel.invokeMethod<bool>('canRequestAds') ?? false;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      return true;
    }
  }

  /// Returns true when the user is in a region (EEA/UK) that requires a
  /// visible privacy-options entry point in the app's settings UI.
  Future<bool> isPrivacyOptionsRequired() async {
    try {
      return await _channel.invokeMethod<bool>('isPrivacyOptionsRequired') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Presents the UMP privacy-options form. Call this from a Settings screen
  /// when [isPrivacyOptionsRequired] returns true.
  Future<void> showPrivacyOptionsForm() async {
    try {
      await _channel.invokeMethod<void>('showPrivacyOptionsForm');
    } on PlatformException {
      // Form unavailable — silently ignore.
    } on MissingPluginException {
      // Non-Android platform — no-op.
    }
  }
}
