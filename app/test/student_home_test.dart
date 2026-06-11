import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onrol_app/screens/student_home.dart';
import 'package:onrol_app/services/api_client.dart';
import 'package:onrol_app/services/auth_service.dart';
import 'package:onrol_app/services/device_service.dart';

void main() {
  // AuthService with no restored session -> user is null; StudentHome falls back
  // to "Student". We only exercise rendering + opening a panel (no network).
  AuthService makeAuth() => AuthService(ApiClient(DeviceService()), DeviceService());

  testWidgets('renders the checkerboard home and opens a panel', (tester) async {
    await tester.pumpWidget(MaterialApp(home: StudentHome(auth: makeAuth())));
    await tester.pumpAndSettle();

    // Brand wordmark present.
    expect(find.text('ONROL'), findsOneWidget);

    // Tap the Settings tile (static, no network) -> its panel opens.
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Push Notifications'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('renders on a narrow phone without layout exceptions', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: StudentHome(auth: makeAuth())));
    await tester.pumpAndSettle();
    expect(find.text('ONROL'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
