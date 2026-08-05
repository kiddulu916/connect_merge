import 'dart:async';
import 'package:google_mobile_ads/google_mobile_ads.dart';

typedef OnConsentGatheringCompleteListener = void Function(FormError? error);

class ConsentManager {
  Future<bool> canRequestAds() async {
    return await ConsentInformation.instance.canRequestAds();
  }

  /// Returns true when the user is in a region (EEA/UK) that requires a
  /// visible privacy-options entry point in the app's settings UI.
  Future<bool> isPrivacyOptionsRequired() async {
    return await ConsentInformation.instance
        .getPrivacyOptionsRequirementStatus() ==
        PrivacyOptionsRequirementStatus.required;
  }

  void gatherConsent(
      OnConsentGatheringCompleteListener onConsentGatheringCompleteListener,
      ) {
    // For testing purposes, you can force a DebugGeography of Eea or NotEea.
    final debugSettings = ConsentDebugSettings(
      // debugGeography: DebugGeography.debugGeographyEea,
    );
    final params = ConsentRequestParameters(
      consentDebugSettings: debugSettings,
    );

    // Requesting an update to consent information should be called on every app launch.
    ConsentInformation.instance.requestConsentInfoUpdate(
      params,
          () async {
        ConsentForm.loadAndShowConsentFormIfRequired((loadAndShowError) {
          // Consent has been gathered.
          onConsentGatheringCompleteListener(loadAndShowError);
        });
      },
          (FormError formError) {
        onConsentGatheringCompleteListener(formError);
      },
    );
  }

  /// Helper method to call the Mobile Ads SDK method to show the privacy options form.
  void showPrivacyOptionsForm(
      OnConsentFormDismissedListener onConsentFormDismissedListener,
      ) {
    ConsentForm.showPrivacyOptionsForm(onConsentFormDismissedListener);
  }
}