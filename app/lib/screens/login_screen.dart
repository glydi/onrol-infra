import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'accounts_portal.dart';
import 'ambassador_portal.dart';
import 'college_portal.dart';
import 'console_screen.dart';
import 'crm_portal.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.auth});
  final AuthService auth;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // One login for everyone — the account's role decides where they land.
      await widget.auth.login(_email.text.trim(), _password.text);
      if (!mounted) return;
      final staff = widget.auth.user?.isStaff ?? false;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => isCrmHost()
            ? CrmPortalScreen(auth: widget.auth)
            : isAmbassadorHost()
                ? AmbassadorPortalScreen(auth: widget.auth)
                : isAccountsHost()
                    ? AccountsPortalScreen(auth: widget.auth)
                    : isCollegeHost()
                        ? CollegePortalScreen(auth: widget.auth)
                        : (staff ? ConsoleScreen(auth: widget.auth) : HomeScreen(auth: widget.auth)),
      ));
    } on ApiException catch (e) {
      setState(() => _error = e.status == 409
          ? 'Device limit reached. Remove a device on another phone and retry.'
          : e.message);
    } catch (e) {
      setState(() => _error = 'Network error. Check your connection.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(13),
                      gradient: const LinearGradient(
                        colors: [AppleColors.blue, AppleColors.purple],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [BoxShadow(color: AppleColors.blue.withOpacity(0.35), blurRadius: 24, offset: const Offset(0, 10))],
                    ),
                    child: const Icon(CupertinoIcons.book_fill, color: Colors.white, size: 38),
                  ),
                ),
                const SizedBox(height: 20),
                Text('ONROL Learn', textAlign: TextAlign.center, style: AppleTheme.largeTitle(context)),
                const SizedBox(height: 6),
                Text('Sign in to your account', textAlign: TextAlign.center, style: AppleTheme.subhead(context)),
                const SizedBox(height: 28),
                AppleCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: [
                      const SizedBox(height: 14),
                      AppleField(controller: _email, hint: 'Email or username', icon: CupertinoIcons.person, keyboard: TextInputType.text),
                      const SizedBox(height: 12),
                      Divider(height: 1, color: p.separator),
                      const SizedBox(height: 12),
                      AppleField(controller: _password, hint: 'Password', icon: CupertinoIcons.lock, obscure: true),
                      const SizedBox(height: 14),
                    ],
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Icon(CupertinoIcons.exclamationmark_circle_fill, color: AppleColors.red, size: 16),
                      const SizedBox(width: 6),
                      Expanded(child: Text(_error!, style: AppleTheme.footnote(context).copyWith(color: AppleColors.red))),
                    ],
                  ),
                ],
                const SizedBox(height: 22),
                PrimaryButton(label: 'Sign In', busy: _busy, onPressed: _busy ? null : _submit),
                const SizedBox(height: 18),
                Text('Students, mentors and admins use the same sign-in.\nYour account decides what you see.',
                    textAlign: TextAlign.center, style: AppleTheme.footnote(context)),
                const SizedBox(height: 22),
                const ThemeToggle(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
