import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'services/api_client.dart';
import 'services/auth_service.dart';
import 'services/device_service.dart';
import 'screens/ambassador_portal.dart';
import 'screens/console_screen.dart';
import 'screens/crm_portal.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'theme.dart';
import 'theme_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  loadTheme();
  runApp(const OnrolApp());
}

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
      builder: (context, mode, _) => MaterialApp(
        title: 'ONROL Learn',
        debugShowCheckedModeBanner: false,
        theme: AppleTheme.light(),
        darkTheme: AppleTheme.dark(),
        themeMode: mode,
        home: FutureBuilder<bool>(
          future: _restored,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Scaffold(body: Center(child: CupertinoActivityIndicator(radius: 14)));
            }
            final hasSession = snap.data == true && _auth.user != null;
            if (!hasSession) return LoginScreen(auth: _auth);
            // Per-portal subdomains route to their own portal.
            if (isCrmHost()) return CrmPortalScreen(auth: _auth);
            if (isAmbassadorHost()) return AmbassadorPortalScreen(auth: _auth);
            return _auth.user!.isStaff ? ConsoleScreen(auth: _auth) : HomeScreen(auth: _auth);
          },
        ),
      ),
    );
  }
}
