// Verifies the user-only gating: the installable mobile app (Android / iOS)
// must be user-only (no staff console / portals), while desktop builds stay
// role-based. Web is covered by kIsWeb at runtime (always false under test).
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:onrol_app/app_mode.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('mobile platforms are user-only', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(kUserOnlyApp, isTrue, reason: 'Android app must be user-only');

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(kUserOnlyApp, isTrue, reason: 'iOS app must be user-only');
  });

  test('desktop platforms stay role-based (not user-only)', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(kUserOnlyApp, isFalse);

    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(kUserOnlyApp, isFalse);

    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(kUserOnlyApp, isFalse);
  });
}
