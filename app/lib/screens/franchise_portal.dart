import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import '../widgets/app_shell.dart';
import '../widgets/profile_view.dart';
import '../widgets/ui.dart';
import 'login_screen.dart';

/// Standalone Franchise Partner portal — served on the `franchise.` subdomain.
/// Admins manage partners + see performance; partners run their branch.
class FranchisePortalScreen extends StatelessWidget {
  const FranchisePortalScreen({super.key, required this.auth});
  final AuthService auth;

  Future<void> _logout(BuildContext context) async {
    await auth.logout();
    if (!context.mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => LoginScreen(auth: auth)));
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = auth.user?.isAdmin ?? false;
    final isPartner = auth.user?.role == 'franchise_partner';
    if (!isAdmin && !isPartner) {
      return Scaffold(body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(CupertinoIcons.lock_fill, size: 48, color: CupertinoColors.systemGrey),
        const SizedBox(height: 16),
        Text('Partners only', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('This portal is for franchise partners and admins.'),
        const SizedBox(height: 24),
        TextButton(onPressed: () => _logout(context), child: const Text('Sign out')),
      ])));
    }
    if (isAdmin) {
      return AppShell(
        auth: auth,
        onSignOut: () => _logout(context),
        destinations: const [
          NavDest(CupertinoIcons.briefcase_fill, 'Franchises'),
          NavDest(CupertinoIcons.person_2_fill, 'Enrollments'),
          NavDest(CupertinoIcons.person_fill, 'Profile'),
        ],
        pages: [
          _AdminFranchises(auth: auth),
          _AdminEnrollments(auth: auth),
          ProfileView(auth: auth, onSignOut: () => _logout(context)),
        ],
      );
    }
    return AppShell(
      auth: auth,
      onSignOut: () => _logout(context),
      destinations: const [
        NavDest(CupertinoIcons.briefcase_fill, 'My Branch'),
        NavDest(CupertinoIcons.person_fill, 'Profile'),
      ],
      pages: [
        _PartnerDashboard(auth: auth),
        ProfileView(auth: auth, onSignOut: () => _logout(context)),
      ],
    );
  }
}

/// True when served from the Franchise subdomain (franchise.*).
bool isFranchiseHost() {
  final h = Uri.base.host;
  return h == 'franchise' || h.startsWith('franchise.');
}

String _money(num paise) {
  final v = paise / 100;
  if (v >= 100000) return '₹${(v / 100000).toStringAsFixed(2)}L';
  if (v >= 1000) return '₹${(v / 1000).toStringAsFixed(1)}K';
  return '₹${v.toStringAsFixed(0)}';
}

Color _enrColor(String s) => switch (s) {
      'paid' => AppleColors.green,
      'dropped' => AppleColors.red,
      _ => AppleColors.orange, // enrolled
    };

Widget _enrollmentCard(BuildContext context, Map<String, dynamic> e, {bool showFranchise = false, VoidCallback? onTap}) {
  final status = e['status']?.toString() ?? 'enrolled';
  final c = _enrColor(status);
  final sub = [e['course'], e['phone'], if (showFranchise && (e['franchise']?.toString() ?? '').isNotEmpty) 'via ${e['franchise']}'].where((x) => (x?.toString() ?? '').isNotEmpty).join(' · ');
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AppleCard(child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(e['student_name']?.toString() ?? 'Student', style: AppleTheme.headline(context)),
          if (sub.isNotEmpty) Text(sub, style: AppleTheme.footnote(context)),
        ])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (((e['fee_paise'] as num?) ?? 0) > 0) Text(_money((e['fee_paise'] as num?) ?? 0), style: AppleTheme.headline(context)),
          Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: c.withOpacity(0.14), borderRadius: BorderRadius.zero), child: Text(status, style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w700))),
        ]),
      ])),
    ),
  );
}

Widget _frFab(VoidCallback onTap, String label) => Builder(builder: (context) => FloatingActionButton.extended(
      onPressed: onTap,
      backgroundColor: Palette.of(context).accent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      icon: const Icon(CupertinoIcons.add, color: Colors.white),
      label: Text(label, style: const TextStyle(color: Colors.white)),
    ));

// ===========================================================================
// Admin — franchises
// ===========================================================================

class _AdminFranchises extends StatefulWidget {
  const _AdminFranchises({required this.auth});
  final AuthService auth;
  @override
  State<_AdminFranchises> createState() => _AdminFranchisesState();
}

class _AdminFranchisesState extends State<_AdminFranchises> {
  bool _loading = true;
  List<dynamic> _items = [];
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { _items = (ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/franchises'))['franchises'] as List?) ?? []; } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }
  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    return Scaffold(
      backgroundColor: Palette.of(context).bg,
      floatingActionButton: _frFab(_create, 'New Franchise'),
      body: RefreshIndicator(onRefresh: _load, child: ListView(padding: EdgeInsets.fromLTRB(hp, 18, hp, 100), children: [
        Text('Franchises', style: AppleTheme.largeTitle(context)),
        Text('${_items.length} partners', style: AppleTheme.subhead(context)),
        const SizedBox(height: 14),
        if (_items.isEmpty) AppleCard(child: Text('No franchises yet. Add a partner — they get a login + branch dashboard.', style: AppleTheme.footnote(context)))
        else ..._items.map((f) => Padding(padding: const EdgeInsets.only(bottom: 12), child: AppleCard(child: Row(children: [
          Container(width: 40, height: 40, alignment: Alignment.center, decoration: BoxDecoration(color: AppleColors.teal.withOpacity(0.14), borderRadius: BorderRadius.zero), child: const Icon(CupertinoIcons.briefcase_fill, color: AppleColors.teal, size: 20)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(f['full_name']?.toString() ?? '', style: AppleTheme.headline(context)),
            Text('${[f['territory'], 'Code ${f['code']}'].where((x) => (x?.toString() ?? '').isNotEmpty).join(' · ')} · ${f['students']} students · ${f['revenue_share']}%', style: AppleTheme.footnote(context)),
          ])),
          if (((f['revenue'] as num?) ?? 0) > 0) Text(_money((f['revenue'] as num?) ?? 0), style: AppleTheme.footnote(context)),
        ])))),
      ])),
    );
  }

  Future<void> _create() async {
    final name = TextEditingController();
    final email = TextEditingController();
    final phone = TextEditingController();
    final pass = TextEditingController();
    final territory = TextEditingController();
    final code = TextEditingController();
    final share = TextEditingController(text: '20');
    final ok = await showFormSheet(context, title: 'New Franchise', builder: (setS) => [
      sheetField(name, 'Partner name', CupertinoIcons.person),
      const SizedBox(height: 10),
      sheetField(email, 'Email (login)', CupertinoIcons.mail, keyboard: TextInputType.emailAddress),
      const SizedBox(height: 10),
      sheetField(phone, 'Phone', CupertinoIcons.phone, keyboard: TextInputType.phone),
      const SizedBox(height: 10),
      sheetField(pass, 'Temp password', CupertinoIcons.lock),
      const SizedBox(height: 10),
      sheetField(territory, 'Territory (e.g. Hyderabad)', CupertinoIcons.location),
      const SizedBox(height: 10),
      sheetField(code, 'Branch code (optional)', CupertinoIcons.tag),
      const SizedBox(height: 10),
      sheetField(share, 'Revenue share (%)', CupertinoIcons.percent, keyboard: TextInputType.number),
    ], onSubmit: () async {
      if (name.text.trim().isEmpty || email.text.trim().isEmpty || pass.text.isEmpty) return 'Name, email and password required';
      try {
        await widget.auth.apiPost('/api/v1/manage/franchises', {
          'full_name': name.text.trim(), 'email': email.text.trim(), 'phone': phone.text.trim(),
          'password': pass.text, 'territory': territory.text.trim(), 'code': code.text.trim(),
          'revenue_share': double.tryParse(share.text.trim()) ?? 0,
        });
        return null;
      } on ApiException catch (e) { return e.message; }
    });
    if (ok == true) { _toast('Franchise created'); _load(); }
  }
}

// ===========================================================================
// Admin — all enrollments
// ===========================================================================

class _AdminEnrollments extends StatefulWidget {
  const _AdminEnrollments({required this.auth});
  final AuthService auth;
  @override
  State<_AdminEnrollments> createState() => _AdminEnrollmentsState();
}

class _AdminEnrollmentsState extends State<_AdminEnrollments> {
  bool _loading = true;
  List<dynamic> _items = [];
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { _items = (ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/franchises/enrollments'))['enrollments'] as List?) ?? []; } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }
  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    return Scaffold(
      backgroundColor: Palette.of(context).bg,
      body: RefreshIndicator(onRefresh: _load, child: ListView(padding: EdgeInsets.fromLTRB(hp, 18, hp, 40), children: [
        Text('Enrollments', style: AppleTheme.largeTitle(context)),
        Text('${_items.length} total', style: AppleTheme.subhead(context)),
        const SizedBox(height: 14),
        if (_items.isEmpty) AppleCard(child: Text('No enrollments yet.', style: AppleTheme.footnote(context)))
        else ..._items.map((e) => _enrollmentCard(context, e as Map<String, dynamic>, showFranchise: true, onTap: () => _manage(e))),
      ])),
    );
  }

  Future<void> _manage(Map<String, dynamic> e) async {
    final id = e['id'].toString();
    final picked = await showModalBottomSheet<String>(
      context: context, backgroundColor: Colors.transparent,
      builder: (ctx) {
        final p = Palette.of(ctx);
        return Container(margin: const EdgeInsets.all(10), decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.zero),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 12), Text('Set status', style: AppleTheme.headline(ctx)), const SizedBox(height: 8),
            for (final s in const ['enrolled', 'paid', 'dropped']) ListTile(leading: Icon(CupertinoIcons.circle, color: _enrColor(s)), title: Text(s, style: AppleTheme.body(ctx)), onTap: () => Navigator.pop(ctx, s)),
            const SizedBox(height: 8),
          ]));
      },
    );
    if (picked == null) return;
    try { await widget.auth.apiPost('/api/v1/manage/franchises/enrollments/$id/status', {'status': picked}); _toast('Marked $picked'); _load(); }
    catch (_) { _toast('Could not update'); }
  }
}

// ===========================================================================
// Partner — branch dashboard
// ===========================================================================

class _PartnerDashboard extends StatefulWidget {
  const _PartnerDashboard({required this.auth});
  final AuthService auth;
  @override
  State<_PartnerDashboard> createState() => _PartnerDashboardState();
}

class _PartnerDashboardState extends State<_PartnerDashboard> {
  bool _loading = true;
  Map<String, dynamic> _me = {};
  List<dynamic> _enr = [];
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try {
      _me = ApiClient.decode(await widget.auth.apiGet('/api/v1/franchise/me'));
      _enr = (ApiClient.decode(await widget.auth.apiGet('/api/v1/franchise/enrollments'))['enrollments'] as List?) ?? [];
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }
  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    Widget stat(String label, String value) => Expanded(child: AppleCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(value, style: AppleTheme.title2(context)),
      Text(label, style: AppleTheme.footnote(context)),
    ])));
    return Scaffold(
      backgroundColor: Palette.of(context).bg,
      floatingActionButton: _frFab(_enroll, 'Enrol Student'),
      body: RefreshIndicator(onRefresh: _load, child: ListView(padding: EdgeInsets.fromLTRB(hp, 18, hp, 100), children: [
        Text('My Branch', style: AppleTheme.largeTitle(context)),
        const SizedBox(height: 12),
        AppleCard(child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_me['territory']?.toString().isEmpty ?? true ? 'Your branch' : _me['territory'].toString(), style: AppleTheme.title2(context)),
            Text('Code ${_me['code'] ?? '—'} · ${_me['revenue_share'] ?? 0}% revenue share', style: AppleTheme.footnote(context)),
          ])),
          Icon(CupertinoIcons.briefcase_fill, color: Palette.of(context).accent, size: 28),
        ])),
        const SizedBox(height: 12),
        Row(children: [stat('Students', '${_me['students'] ?? 0}'), const SizedBox(width: 12), stat('Paid', '${_me['paid'] ?? 0}')]),
        const SizedBox(height: 12),
        Row(children: [stat('Revenue', _money((_me['revenue'] as num?) ?? 0)), const SizedBox(width: 12), stat('My share', _money((_me['my_share'] as num?) ?? 0))]),
        const SizedBox(height: 20),
        Text('My students', style: AppleTheme.headline(context)),
        const SizedBox(height: 8),
        if (_enr.isEmpty) AppleCard(child: Text('No students yet — tap "Enrol Student" to add one.', style: AppleTheme.footnote(context)))
        else ..._enr.map((e) => _enrollmentCard(context, e as Map<String, dynamic>)),
      ])),
    );
  }

  Future<void> _enroll() async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final course = TextEditingController();
    final fee = TextEditingController();
    final ok = await showFormSheet(context, title: 'Enrol Student', builder: (setS) => [
      sheetField(name, 'Student name', CupertinoIcons.person),
      const SizedBox(height: 10),
      sheetField(phone, 'Phone', CupertinoIcons.phone, keyboard: TextInputType.phone),
      const SizedBox(height: 10),
      sheetField(course, 'Course', CupertinoIcons.book),
      const SizedBox(height: 10),
      sheetField(fee, 'Fee (₹)', CupertinoIcons.money_dollar, keyboard: TextInputType.number),
    ], onSubmit: () async {
      if (name.text.trim().isEmpty) return 'Name required';
      try {
        await widget.auth.apiPost('/api/v1/franchise/enrollments', {
          'student_name': name.text.trim(), 'phone': phone.text.trim(), 'course': course.text.trim(),
          'fee_paise': ((double.tryParse(fee.text.trim()) ?? 0) * 100).round(),
        });
        return null;
      } on ApiException catch (e) { return e.message; }
    });
    if (ok == true) { _toast('Student enrolled'); _load(); }
  }
}
