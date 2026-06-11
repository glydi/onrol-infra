import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../widgets/app_shell.dart';
import '../widgets/profile_view.dart';
import 'crm_screen.dart';
import 'login_screen.dart';

/// Standalone CRM portal — served on the `crm.` subdomain. Same backend/login,
/// but the whole app is just the CRM (no LMS console or student home).
class CrmPortalScreen extends StatelessWidget {
  const CrmPortalScreen({super.key, required this.auth});
  final AuthService auth;

  Future<void> _logout(BuildContext context) async {
    await auth.logout();
    if (!context.mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => LoginScreen(auth: auth)));
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      auth: auth,
      onSignOut: () => _logout(context),
      destinations: const [
        NavDest(CupertinoIcons.person_crop_circle_badge_checkmark, 'CRM'),
        NavDest(CupertinoIcons.person_fill, 'Profile'),
      ],
      pages: [
        CrmScreen(auth: auth),
        ProfileView(auth: auth, onSignOut: () => _logout(context)),
      ],
    );
  }
}

/// True when the app is being served from the CRM subdomain (crm.*).
bool isCrmHost() {
  final host = Uri.base.host;
  return host == 'crm' || host.startsWith('crm.');
}

/// The CRM portal URL for the current deployment — the same domain with a
/// `crm.` host prefix (e.g. lms.example.com → crm.example.com).
String crmUrl() {
  final b = Uri.base;
  var host = b.host;
  for (final prefix in const ['crm.', 'lms.']) {
    if (host.startsWith(prefix)) {
      host = host.substring(prefix.length);
      break;
    }
  }
  final port = (b.hasPort && b.port != 0 && b.port != 443 && b.port != 80) ? ':${b.port}' : '';
  return 'https://crm.$host$port/';
}
