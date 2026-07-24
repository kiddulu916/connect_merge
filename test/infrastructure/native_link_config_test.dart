import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android owns only canonical invite App Links via app_links', () async {
    final manifest =
        await File('android/app/src/main/AndroidManifest.xml').readAsString();

    expect(
      manifest,
      contains('android:name="flutter_deeplinking_enabled"'),
    );
    expect(manifest, contains('android:value="false"'));
    expect(
      manifest,
      contains('android:host="www.connectmerge.app"'),
    );
    expect(manifest, contains('android:pathPrefix="/invite/"'));
    expect(manifest, isNot(contains('android:host="connectmerge.app"')));
  });

  test('iOS disables Flutter built-in deep-link handling', () async {
    final plist = await File('ios/Runner/Info.plist').readAsString();

    expect(plist, contains('<key>FlutterDeepLinkingEnabled</key>'));
    expect(
      plist.indexOf('<false/>'),
      greaterThan(plist.indexOf('<key>FlutterDeepLinkingEnabled</key>')),
    );
  });
}
