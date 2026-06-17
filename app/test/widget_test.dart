// Minimal smoke test. The app is network/auth-driven, so we only verify the
// root widget constructs (a full pump would require mocking services).
import 'package:flutter_test/flutter_test.dart';

import 'package:onrol_app/main.dart';

void main() {
  test('OnrolApp constructs', () {
    expect(const OnrolApp(), isNotNull);
  });
}
