import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import 'ui.dart';

/// Shared profile page: identity, edit, appearance, sign out. Used by both the
/// student dashboard and the staff console.
class ProfileView extends StatefulWidget {
  const ProfileView({super.key, required this.auth, required this.onSignOut});
  final AuthService auth;
  final VoidCallback onSignOut;

  @override
  State<ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<ProfileView> {
  double _hp(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return (w > 712 ? ((w > 1180 ? w - 256 : w) - 680) / 2 : 18.0).clamp(18, 400).toDouble();
  }

  // Change the signed-in account's own password (current + new).
  Future<void> _changePassword() async {
    final cur = TextEditingController();
    final nw = TextEditingController();
    final ok = await showFormSheet(context, title: 'Change Password', builder: (_) => [
      sheetField(cur, 'Current password', CupertinoIcons.lock, obscure: true),
      const SizedBox(height: 10),
      sheetField(nw, 'New password (min 8)', CupertinoIcons.lock_fill, obscure: true),
    ], onSubmit: () async {
      if (nw.text.trim().length < 8) return 'New password must be at least 8 characters';
      try {
        final r = await widget.auth.apiPost('/api/v1/me/password', {'current_password': cur.text, 'new_password': nw.text.trim()});
        ApiClient.decode(r); // throws on non-2xx
        return null;
      } on ApiException catch (e) {
        return e.message;
      } catch (_) {
        return 'Could not update password';
      }
    });
    if (ok == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password updated'), behavior: SnackBarBehavior.floating));
    }
  }

  Future<void> _edit() async {
    final name = TextEditingController(text: widget.auth.user?.fullName ?? '');
    final phone = TextEditingController();
    final p = Palette.of(context);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        bool busy = false;
        String? err;
        return StatefulBuilder(builder: (ctx, setS) {
          Widget field(TextEditingController c, String hint, IconData icon) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                decoration: BoxDecoration(color: p.card2, borderRadius: BorderRadius.zero),
                child: AppleField(controller: c, hint: hint, icon: icon),
              );
          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: Container(
              margin: const EdgeInsets.all(10),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.zero),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Center(child: Text('Edit Profile', style: AppleTheme.title2(ctx))),
                const SizedBox(height: 16),
                field(name, 'Full name', CupertinoIcons.person),
                const SizedBox(height: 10),
                field(phone, 'Phone (optional)', CupertinoIcons.phone),
                if (err != null) ...[const SizedBox(height: 10), Text(err!, style: AppleTheme.footnote(ctx).copyWith(color: AppleColors.red))],
                const SizedBox(height: 18),
                PrimaryButton(
                  label: 'Save',
                  busy: busy,
                  onPressed: () async {
                    if (name.text.trim().isEmpty) {
                      setS(() => err = 'Name is required');
                      return;
                    }
                    setS(() { busy = true; err = null; });
                    try {
                      await widget.auth.apiPatch('/api/v1/me/profile', {
                        'full_name': name.text.trim(),
                        if (phone.text.trim().isNotEmpty) 'phone': phone.text.trim(),
                      });
                      await widget.auth.refreshProfile();
                      if (ctx.mounted) Navigator.pop(ctx);
                    } catch (_) {
                      setS(() { busy = false; err = 'Could not save'; });
                    }
                  },
                ),
                const SizedBox(height: 6),
                TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: p.secondary))),
              ]),
            ),
          );
        });
      },
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final hp = _hp(context);
    final u = widget.auth.user;
    return ListView(
      padding: EdgeInsets.fromLTRB(hp, 22, hp, 40),
      children: [
        Text('Profile', style: AppleTheme.largeTitle(context)),
        const SizedBox(height: 18),
        AppleCard(
          child: Column(children: [
            Avatar(name: u?.fullName ?? 'U', size: 64),
            const SizedBox(height: 12),
            Text(u?.fullName ?? 'User', style: AppleTheme.title2(context)),
            Text(u?.email ?? '', style: AppleTheme.footnote(context)),
            const SizedBox(height: 6),
            Text((u?.role ?? 'student').toUpperCase(),
                style: AppleTheme.footnote(context).copyWith(color: Palette.of(context).accent, fontWeight: FontWeight.w700)),
            // Students see their course + which batch they're in.
            if (u?.role == 'student' && ((u?.course.isNotEmpty ?? false) || u?.batch != null)) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Palette.of(context).accent.withOpacity(0.12),
                  borderRadius: BorderRadius.zero,
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(CupertinoIcons.square_stack_3d_up, size: 16, color: Palette.of(context).accent),
                  const SizedBox(width: 8),
                  Text(
                    [
                      if (u!.course.isNotEmpty) u.course,
                      u.batch != null ? 'Batch ${u.batch}' : 'Batch: not assigned yet',
                    ].join(' · '),
                    style: AppleTheme.footnote(context).copyWith(color: Palette.of(context).accent, fontWeight: FontWeight.w600),
                  ),
                ]),
              ),
            ],
            const SizedBox(height: 14),
            GestureDetector(
              onTap: _edit,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                decoration: BoxDecoration(color: Palette.of(context).accent.withOpacity(0.12), borderRadius: BorderRadius.zero),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(CupertinoIcons.pencil, size: 15, color: Palette.of(context).accent),
                  const SizedBox(width: 6),
                  Text('Edit Profile', style: TextStyle(color: Palette.of(context).accent, fontWeight: FontWeight.w600, fontSize: 14)),
                ]),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 18),
        Text('Appearance', style: AppleTheme.footnote(context)),
        const SizedBox(height: 8),
        const ThemeToggle(),
        const SizedBox(height: 18),
        Text('Security', style: AppleTheme.footnote(context)),
        const SizedBox(height: 8),
        PrimaryButton(label: 'Change Password', icon: CupertinoIcons.lock_fill, square: true, onPressed: _changePassword),
        const SizedBox(height: 22),
        PrimaryButton(label: 'Sign Out', icon: CupertinoIcons.square_arrow_right, onPressed: widget.onSignOut),
      ],
    );
  }
}
