import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'services/api_client.dart';
import 'services/auth_service.dart';
import 'services/device_service.dart';
import 'screens/accounts_portal.dart';
import 'screens/ambassador_portal.dart';
import 'screens/college_portal.dart';
import 'screens/console_screen.dart';
import 'screens/franchise_portal.dart';
import 'screens/crm_portal.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'theme.dart';
import 'theme_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  loadTheme();
  loadAvatar();
  loadTextScale();
  loadAccent();
  runApp(const OnrolApp());
}

/// When built with --dart-define=STUDENT_APP=true (the Windows student app),
/// the app is a dedicated, light student LMS: it always lands on the student
/// home and never shows the staff console or the per-portal subdomain screens.
const bool kStudentApp = bool.fromEnvironment('STUDENT_APP');

class OnrolApp extends StatefulWidget {
  const OnrolApp({super.key});

  @override
  State<OnrolApp> createState() => _OnrolAppState();
}

class _OnrolAppState extends State<OnrolApp> {
  late final DeviceService _device = DeviceService();
  late final ApiClient _api = ApiClient(_device);
  late final AuthService _auth = AuthService(_api, _device);
  late final Future<bool> _restored = _auth.restore();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, mode, _) => ValueListenableBuilder<double>(
        valueListenable: textScaleNotifier,
        builder: (context, scale, __) => MaterialApp(
        title: 'ONROL Learn',
        debugShowCheckedModeBanner: false,
        theme: AppleTheme.light(),
        darkTheme: AppleTheme.dark(),
        themeMode: mode,
        // Apply the user's chosen font size app-wide.
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: FutureBuilder<bool>(
          future: _restored,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Scaffold(body: Center(child: CupertinoActivityIndicator(radius: 14)));
            }
            final hasSession = snap.data == true && _auth.user != null;
            if (!hasSession) return LoginScreen(auth: _auth);
            // Dedicated student app (Windows): always the student LMS, nothing else.
            if (kStudentApp) return HomeScreen(auth: _auth);
            // Per-portal subdomains route to their own portal.
            if (isCrmHost()) return CrmPortalScreen(auth: _auth);
            if (isAmbassadorHost()) return AmbassadorPortalScreen(auth: _auth);
            if (isAccountsHost()) return AccountsPortalScreen(auth: _auth);
            if (isCollegeHost()) return CollegePortalScreen(auth: _auth);
            if (isFranchiseHost()) return FranchisePortalScreen(auth: _auth);
            return _auth.user!.isStaff ? ConsoleScreen(auth: _auth) : HomeScreen(auth: _auth);
          },
        ),
      ),
      ),
    );
  }
}
