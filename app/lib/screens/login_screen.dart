import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

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
  final _totp = TextEditingController();
  bool _busy = false;
  bool _needTotp = false; // account has 2FA — show the code field
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // One login for everyone — the account's role decides where they land.
      await widget.auth.login(_email.text.trim(), _password.text, totp: _needTotp ? _totp.text.trim() : null);
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
                        : isFranchiseHost()
                            ? FranchisePortalScreen(auth: widget.auth)
                            : (staff ? ConsoleScreen(auth: widget.auth) : HomeScreen(auth: widget.auth)),
      ));
    } on ApiException catch (e) {
      // Account has 2FA: reveal the code field and prompt for it.
      if (e.data?['totp_required'] == true) {
        setState(() {
          _needTotp = true;
          _error = _totp.text.trim().isEmpty ? 'Enter the 6-digit code from your authenticator app.' : 'Invalid code — try again.';
        });
        return;
      }
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
    final dark = Theme.of(context).brightness == Brightness.dark;
    final label = dark ? const Color(0xFFECEDF2) : const Color(0xFF1A1A2E);
    final grey = dark ? const Color(0xFF9AA0AC) : const Color(0xFF888888);
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: _LoginBackdrop(dark: dark)),
          Center(
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
                          borderRadius: BorderRadius.circular(18),
                          gradient: const LinearGradient(
                            colors: [_orange, Color(0xFFFF7A4D)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          boxShadow: [BoxShadow(color: _orange.withOpacity(0.4), blurRadius: 24, offset: const Offset(0, 10))],
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
                    Text('Sign in to your account', textAlign: TextAlign.center, style: GoogleFonts.poppins(fontSize: 14, color: grey)),
                    const SizedBox(height: 28),
                    _glassCard(
                      dark: dark,
                      child: Column(
                        children: [
                          const SizedBox(height: 14),
                          AppleField(controller: _email, hint: 'Email or username', icon: CupertinoIcons.person, keyboard: TextInputType.text),
                          const SizedBox(height: 12),
                          Divider(height: 1, color: p.separator),
                          const SizedBox(height: 12),
                          AppleField(controller: _password, hint: 'Password', icon: CupertinoIcons.lock, obscure: true),
                          if (_needTotp) ...[
                            const SizedBox(height: 12),
                            Divider(height: 1, color: p.separator),
                            const SizedBox(height: 12),
                            AppleField(controller: _totp, hint: '6-digit code', icon: CupertinoIcons.shield_lefthalf_fill, keyboard: TextInputType.number),
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
                    const SizedBox(height: 22),
                    _signInButton(),
                    const SizedBox(height: 18),
                    Text('Students, mentors and admins use the same sign-in.\nYour account decides what you see.',
                        textAlign: TextAlign.center, style: GoogleFonts.poppins(fontSize: 12, color: grey, height: 1.5)),
                    const SizedBox(height: 22),
                    const ThemeToggle(),
                  ],
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
    final r = BorderRadius.circular(20);
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
  Widget _signInButton() => GestureDetector(
        onTap: _busy ? null : _submit,
        child: Container(
          height: 50,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [_orange, Color(0xFFFF7A4D)], begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [BoxShadow(color: _orange.withOpacity(0.4), blurRadius: 14, offset: const Offset(0, 6))],
          ),
          child: _busy
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
              : Text('Sign In', style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
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
          colors: dark ? const [Color(0xFF0E0F14), Color(0xFF14161F)] : const [Color(0xFFFFF1EA), Color(0xFFFDEAF6)],
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
