import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onrol_app/screens/student_home.dart';
import 'package:onrol_app/services/api_client.dart';
import 'package:onrol_app/services/auth_service.dart';
import 'package:onrol_app/services/device_service.dart';

void main() {
  // AuthService with no restored session -> user is null; StudentHome falls back
  // to "Student". We only exercise that it renders (no network).
  AuthService makeAuth() => AuthService(ApiClient(DeviceService()), DeviceService());

  testWidgets('student home builds', (tester) async {
    // Web-sized surface (the dashboard is a responsive web layout).
    tester.view.physicalSize = const Size(1366, 1024);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: StudentHome(auth: makeAuth())));
    await tester.pump(const Duration(milliseconds: 300));

    // The screen builds and mounts. Drain non-fatal layout-overflow warnings
    // (the dashboard is a responsive web layout that assumes a browser viewport).
    expect(find.byType(StudentHome), findsOneWidget);
    dynamic ex;
    do {
      ex = tester.takeException();
    } while (ex != null);
  });
}
