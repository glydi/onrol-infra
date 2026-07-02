import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app_mode.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'accounts_portal.dart';
import 'ambassador_portal.dart';
import 'college_portal.dart';
import 'console_screen.dart';
import 'franchise_portal.dart';
import 'crm_portal.dart';
import 'home_screen.dart';
import 'live_host_portal.dart';

// Matches the LMS dashboard theme: orange accent + frosted glass on a soft,
// blurred colour backdrop.
const _orange = Color(0xFFFF4F2B);

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

  // Forgot-password (OTP) flow.
  final _fpEmail = TextEditingController();
  final _fpCode = TextEditingController();
  final _fpNew = TextEditingController();
  bool _forgot = false; // showing the reset flow
  bool _otpSent = false; // code has been emailed → show code + new password
  bool _remember = true; // remember email + password for next login

  @override
  void initState() {
    super.initState();
    // Prefill the last-used credentials so signing back in after logout is one tap.
    widget.auth.savedCredentials().then((c) {
      if (c != null && mounted) {
        setState(() {
          _email.text = c.$1;
          _password.text = c.$2;
        });
      }
    });
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // One login for everyone — the account's role decides where they land.
      await widget.auth.login(_email.text.trim(), _password.text);
      // Remember (or forget) the credentials for next time.
      if (_remember) {
        await widget.auth.saveCredentials(_email.text.trim(), _password.text);
      } else {
        await widget.auth.clearCredentials();
      }
      // Tell the platform the login is done so the browser / password manager
      // offers to save these credentials.
      TextInput.finishAutofillContext();
      if (!mounted) return;
      _goHome();
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

  void _goHome() {
    final staff = widget.auth.user?.isStaff ?? false;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      // User-only apps (mobile / student build) always land on the user home —
      // no console or portal screens, whatever the role.
      builder: (_) => kUserOnlyApp
          ? HomeScreen(auth: widget.auth)
          : isCrmHost()
              ? CrmPortalScreen(auth: widget.auth)
              : isAmbassadorHost()
                  ? AmbassadorPortalScreen(auth: widget.auth)
                  : isAccountsHost()
                      ? AccountsPortalScreen(auth: widget.auth)
                      : isCollegeHost()
                          ? CollegePortalScreen(auth: widget.auth)
                          : isFranchiseHost()
                              ? FranchisePortalScreen(auth: widget.auth)
                              : (widget.auth.user?.isLiveHost == true
                                  ? LiveHostPortalScreen(auth: widget.auth)
                                  : (staff ? ConsoleScreen(auth: widget.auth) : HomeScreen(auth: widget.auth))),
    ));
  }

  // Step 1 of reset: email a 6-digit code.
  Future<void> _sendReset() async {
    final email = _fpEmail.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Enter your account email.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      ApiClient.decode(await widget.auth.apiPost('/api/v1/auth/forgot', {'email': email}));
      if (mounted) setState(() => _otpSent = true);
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't send the code. Try again.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Step 2 of reset: verify the code, set the new password, then sign in.
  Future<void> _doReset() async {
    final email = _fpEmail.text.trim();
    final code = _fpCode.text.trim();
    final np = _fpNew.text;
    if (code.length < 6) {
      setState(() => _error = 'Enter the 6-digit code we emailed you.');
      return;
    }
    if (np.length < 8) {
      setState(() => _error = 'New password must be at least 8 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      ApiClient.decode(await widget.auth.apiPost('/api/v1/auth/reset', {'email': email, 'code': code, 'new_password': np}));
      await widget.auth.login(email, np); // auto sign-in with the new password
      if (!mounted) return;
      _goHome();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't reset. Check the code and try again.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggleForgot(bool on) => setState(() {
        _forgot = on;
        _otpSent = false;
        _error = null;
        _fpCode.clear();
        _fpNew.clear();
        if (on) _fpEmail.text = _email.text.trim();
      });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final label = dark ? const Color(0xFFECEDF2) : const Color(0xFF1A1A2E);
    final grey = dark ? const Color(0xFF9AA0AC) : const Color(0xFF888888);
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: _LoginBackdrop(dark: dark)),
          Center(
            child: ScrollConfiguration(
              // Hide the scrollbar on the login page (esp. web).
              behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
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
                        width: 80,
                        height: 80,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.zero,
                          gradient: const LinearGradient(
                            colors: [_orange, Color(0xFFFF7A4D)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                        ),
                        child: const Icon(CupertinoIcons.book_fill, color: Colors.white, size: 38),
                      ),
                    ),
                    const SizedBox(height: 22),
                    RichText(
                      textAlign: TextAlign.center,
                      text: TextSpan(children: [
                        TextSpan(text: 'ONROL ', style: GoogleFonts.poppins(fontSize: 28, fontWeight: FontWeight.w800, color: label)),
                        TextSpan(text: 'Learn', style: GoogleFonts.poppins(fontSize: 28, fontWeight: FontWeight.w800, color: _orange)),
                      ]),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _forgot ? (_otpSent ? 'Enter the code we emailed you' : 'Reset your password') : 'Sign in to your account',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.poppins(fontSize: 14, color: grey),
                    ),
                    const SizedBox(height: 28),
                    _glassCard(
                      dark: dark,
                      child: Column(
                        children: [
                          const SizedBox(height: 14),
                          if (!_forgot) ...[
                            AppleField(controller: _email, hint: 'Email or username', icon: CupertinoIcons.person, keyboard: TextInputType.text, autofillHints: const [AutofillHints.username, AutofillHints.email]),
                            const SizedBox(height: 12),
                            Divider(height: 1, color: p.separator),
                            const SizedBox(height: 12),
                            AppleField(controller: _password, hint: 'Password', icon: CupertinoIcons.lock, obscure: true, autofillHints: const [AutofillHints.password]),
                          ] else if (!_otpSent) ...[
                            AppleField(controller: _fpEmail, hint: 'Your account email', icon: CupertinoIcons.mail, keyboard: TextInputType.emailAddress),
                          ] else ...[
                            AppleField(controller: _fpCode, hint: '6-digit code', icon: CupertinoIcons.number, keyboard: TextInputType.number),
                            const SizedBox(height: 12),
                            Divider(height: 1, color: p.separator),
                            const SizedBox(height: 12),
                            AppleField(controller: _fpNew, hint: 'New password', icon: CupertinoIcons.lock, obscure: true),
                          ],
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
                          Expanded(child: Text(_error!, style: GoogleFonts.poppins(fontSize: 12.5, color: AppleColors.red))),
                        ],
                      ),
                    ],
                    if (!_forgot) ...[
                      const SizedBox(height: 14),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => _remember = !_remember),
                        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            width: 20, height: 20, alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: _remember ? _orange : Colors.transparent,
                              borderRadius: BorderRadius.zero,
                              border: Border.all(color: _remember ? _orange : grey.withOpacity(0.5), width: 1.5),
                            ),
                            child: _remember ? const Icon(CupertinoIcons.checkmark_alt, size: 14, color: Colors.white) : null,
                          ),
                          const SizedBox(width: 8),
                          Text('Remember me', style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: label)),
                        ]),
                      ),
                    ],
                    const SizedBox(height: 22),
                    if (!_forgot)
                      _primaryButton('Sign In', _submit)
                    else if (!_otpSent)
                      _primaryButton('Send code', _sendReset)
                    else
                      _primaryButton('Reset & sign in', _doReset),
                    const SizedBox(height: 14),
                    // Forgot-password / back links.
                    if (!_forgot)
                      GestureDetector(
                        onTap: () => _toggleForgot(true),
                        child: Text('Forgot password?', textAlign: TextAlign.center, style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: _orange)),
                      )
                    else
                      GestureDetector(
                        onTap: () => _toggleForgot(false),
                        child: Text('← Back to sign in', textAlign: TextAlign.center, style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: _orange)),
                      ),
                    const SizedBox(height: 16),
                    if (!_forgot)
                      Text('Students, mentors and admins use the same sign-in.\nYour account decides what you see.',
                          textAlign: TextAlign.center, style: GoogleFonts.poppins(fontSize: 12, color: grey, height: 1.5)),
                    const SizedBox(height: 22),
                    const ThemeToggle(),
                  ],
                ),
              ),
            ),
            ),
          ),
        ],
      ),
    );
  }

  // Frosted-glass container (matches the LMS cards).
  Widget _glassCard({required bool dark, required Widget child}) {
    final r = BorderRadius.zero;
    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: dark ? Colors.white.withOpacity(0.07) : Colors.white.withOpacity(0.6),
            borderRadius: r,
            border: Border.all(color: dark ? Colors.white.withOpacity(0.12) : Colors.white.withOpacity(0.7), width: 1),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(dark ? 0.3 : 0.07), blurRadius: 30, offset: const Offset(0, 14))],
          ),
          child: child,
        ),
      ),
    );
  }

  // Orange gradient primary button with a busy spinner.
  Widget _primaryButton(String label, VoidCallback onTap) => GestureDetector(
        onTap: _busy ? null : onTap,
        child: Container(
          height: 46,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [_orange, Color(0xFFFF7A4D)], begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.zero,
          ),
          child: _busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
              : Text(label, style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white)),
        ),
      );
}

/// Soft, blurred colour backdrop — the same look as the LMS dashboard.
class _LoginBackdrop extends StatelessWidget {
  const _LoginBackdrop({required this.dark});
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final blob = ui.ImageFilter.blur(sigmaX: 90, sigmaY: 90);
    Widget circle(Color c, double d) => ImageFiltered(
          imageFilter: blob,
          child: Container(width: d, height: d, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        );
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark ? const [Color(0xFF0E0F14), Color(0xFF14161F)] : const [Color(0xFFF4F5F7), Color(0xFFF4F5F7)],
        ),
      ),
      child: Stack(children: [
        Positioned(top: -120, left: -100, child: circle(_orange.withOpacity(dark ? 0.22 : 0.30), 380)),
        Positioned(top: 100, right: -140, child: circle(const Color(0xFFFF7A4D).withOpacity(dark ? 0.18 : 0.28), 420)),
        Positioned(bottom: -160, left: 120, child: circle(const Color(0xFF7C5CFF).withOpacity(dark ? 0.16 : 0.18), 460)),
      ]),
    );
  }
}
