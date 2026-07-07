import 'package:flutter/cupertino.dart' hide Text;
import 'package:flutter/material.dart' hide Text;
import 'package:onrol_app/widgets/upper_text.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import '../widgets/app_shell.dart';
import '../widgets/profile_view.dart';
import '../widgets/ui.dart';
import 'login_screen.dart';

/// Standalone Ambassador portal — served on the `ambassador.` subdomain.
/// Admins manage ambassadors + referrals; ambassadors see their own dashboard.
class AmbassadorPortalScreen extends StatelessWidget {
  const AmbassadorPortalScreen({super.key, required this.auth});
  final AuthService auth;

  Future<void> _logout(BuildContext context) async {
    await auth.logout();
    if (!context.mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => LoginScreen(auth: auth)));
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = auth.user?.isAdmin ?? false;
    final isAmbassador = auth.user?.role == 'ambassador';
    if (!isAdmin && !isAmbassador) return _denied(context);

    if (isAdmin) {
      return AppShell(
        auth: auth,
        onSignOut: () => _logout(context),
        destinations: const [
          NavDest(CupertinoIcons.person_2_fill, 'Ambassadors'),
          NavDest(CupertinoIcons.arrow_branch, 'Referrals'),
          NavDest(CupertinoIcons.person_fill, 'Profile'),
        ],
        pages: [
          _AdminAmbassadors(auth: auth),
          _AdminReferrals(auth: auth),
          ProfileView(auth: auth, onSignOut: () => _logout(context)),
        ],
      );
    }
    return AppShell(
      auth: auth,
      onSignOut: () => _logout(context),
      destinations: const [
        NavDest(CupertinoIcons.gift_fill, 'My Referrals'),
        NavDest(CupertinoIcons.person_fill, 'Profile'),
      ],
      pages: [
        _AmbassadorDashboard(auth: auth),
        ProfileView(auth: auth, onSignOut: () => _logout(context)),
      ],
    );
  }

  Widget _denied(BuildContext context) => Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(CupertinoIcons.lock_fill, size: 48, color: CupertinoColors.systemGrey),
            const SizedBox(height: 16),
            Text('Ambassadors only', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('This portal is for ambassadors and admins.'),
            const SizedBox(height: 24),
            TextButton(onPressed: () => _logout(context), child: const Text('Sign out')),
          ]),
        ),
      );
}

/// True when served from the Ambassador subdomain (ambassador.*).
bool isAmbassadorHost() {
  final h = Uri.base.host;
  return h == 'ambassador' || h.startsWith('ambassador.');
}

String _money(num paise) {
  final v = paise / 100;
  if (v >= 100000) return '₹${(v / 100000).toStringAsFixed(2)}L';
  if (v >= 1000) return '₹${(v / 1000).toStringAsFixed(1)}K';
  return '₹${v.toStringAsFixed(0)}';
}

Color _refColor(String s) => switch (s) {
      'rewarded' => AppleColors.green,
      'enrolled' => AppleColors.blue,
      'contacted' => AppleColors.orange,
      'rejected' => AppleColors.red,
      _ => const Color(0xFF8E8E93),
    };

// ===========================================================================
// Admin — ambassadors list + create
// ===========================================================================

class _AdminAmbassadors extends StatefulWidget {
  const _AdminAmbassadors({required this.auth});
  final AuthService auth;
  @override
  State<_AdminAmbassadors> createState() => _AdminAmbassadorsState();
}

class _AdminAmbassadorsState extends State<_AdminAmbassadors> {
  bool _loading = true;
  List<dynamic> _items = [];
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { _items = (ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/ambassadors'))['ambassadors'] as List?) ?? []; } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }
  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    return Scaffold(
      backgroundColor: Palette.of(context).bg,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        backgroundColor: Palette.of(context).accent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        icon: const Icon(CupertinoIcons.add, color: Colors.white),
        label: const Text('New Ambassador', style: TextStyle(color: Colors.white)),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: EdgeInsets.fromLTRB(hp, 18, hp, 100), children: [
          Text('Ambassadors', style: AppleTheme.largeTitle(context)),
          Text('${_items.length} total', style: AppleTheme.subhead(context)),
          const SizedBox(height: 14),
          if (_items.isEmpty)
            AppleCard(child: Text('No ambassadors yet. Add one — they get a login + referral code.', style: AppleTheme.footnote(context)))
          else
            ..._items.map((a) => _card(a as Map<String, dynamic>)),
        ]),
      ),
    );
  }

  Widget _card(Map<String, dynamic> a) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: AppleCard(child: Row(children: [
          Avatar(name: a['full_name']?.toString() ?? '?', size: 40),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(a['full_name']?.toString() ?? '', style: AppleTheme.headline(context)),
            Text('Code ${a['code']} · ${a['referrals']} referrals · ${a['converted']} converted', style: AppleTheme.footnote(context)),
          ])),
          if (((a['earned'] as num?) ?? 0) > 0) Text('${_money((a['earned'] as num?) ?? 0)} paid', style: AppleTheme.footnote(context)),
        ])),
      );

  Future<void> _create() async {
    final name = TextEditingController();
    final email = TextEditingController();
    final phone = TextEditingController();
    final pass = TextEditingController();
    final code = TextEditingController();
    final ok = await showFormSheet(context, title: 'New Ambassador', builder: (setS) => [
      sheetField(name, 'Full name', CupertinoIcons.person),
      const SizedBox(height: 10),
      sheetField(email, 'Email (login)', CupertinoIcons.mail, keyboard: TextInputType.emailAddress),
      const SizedBox(height: 10),
      sheetField(phone, 'Phone', CupertinoIcons.phone, keyboard: TextInputType.phone),
      const SizedBox(height: 10),
      sheetField(pass, 'Temp password', CupertinoIcons.lock),
      const SizedBox(height: 10),
      sheetField(code, 'Referral code (optional)', CupertinoIcons.tag),
    ], onSubmit: () async {
      if (name.text.trim().isEmpty || email.text.trim().isEmpty || pass.text.isEmpty) return 'Name, email and password required';
      try {
        await widget.auth.apiPost('/api/v1/manage/ambassadors', {
          'full_name': name.text.trim(), 'email': email.text.trim(), 'phone': phone.text.trim(),
          'password': pass.text, 'code': code.text.trim(),
        });
        return null;
      } on ApiException catch (e) { return e.message; }
    });
    if (ok == true) { _toast('Ambassador created'); _load(); }
  }
}

// ===========================================================================
// Admin — all referrals + status/reward
// ===========================================================================

class _AdminReferrals extends StatefulWidget {
  const _AdminReferrals({required this.auth});
  final AuthService auth;
  @override
  State<_AdminReferrals> createState() => _AdminReferralsState();
}

class _AdminReferralsState extends State<_AdminReferrals> {
  bool _loading = true;
  List<dynamic> _items = [];
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { _items = (ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/ambassadors/referrals'))['referrals'] as List?) ?? []; } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }
  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    return Scaffold(
      backgroundColor: Palette.of(context).bg,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: EdgeInsets.fromLTRB(hp, 18, hp, 40), children: [
          Text('Referrals', style: AppleTheme.largeTitle(context)),
          Text('${_items.length} total', style: AppleTheme.subhead(context)),
          const SizedBox(height: 14),
          if (_items.isEmpty)
            AppleCard(child: Text('No referrals yet.', style: AppleTheme.footnote(context)))
          else
            ..._items.map((r) => _card(r as Map<String, dynamic>)),
        ]),
      ),
    );
  }

  Widget _card(Map<String, dynamic> r) {
    final status = r['status']?.toString() ?? 'new';
    final c = _refColor(status);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: () => _manage(r),
        behavior: HitTestBehavior.opaque,
        child: AppleCard(child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r['name']?.toString() ?? '', style: AppleTheme.headline(context)),
            Text('by ${r['ambassador']} · ${[r['phone'], r['email']].where((x) => (x?.toString() ?? '').isNotEmpty).join(' · ')}', style: AppleTheme.footnote(context)),
          ])),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: c.withOpacity(0.14), borderRadius: BorderRadius.zero), child: Text(status, style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w700))),
            if (((r['reward_paise'] as num?) ?? 0) > 0) Padding(padding: const EdgeInsets.only(top: 4), child: Text(_money((r['reward_paise'] as num?) ?? 0), style: AppleTheme.footnote(context))),
          ]),
        ])),
      ),
    );
  }

  Future<void> _manage(Map<String, dynamic> r) async {
    final id = r['id'].toString();
    final reward = TextEditingController(text: (((r['reward_paise'] as num?) ?? 0) / 100).toStringAsFixed(0));
    int status = ['new', 'contacted', 'enrolled', 'rewarded', 'rejected'].indexOf(r['status']?.toString() ?? 'new');
    if (status < 0) status = 0;
    final ok = await showFormSheet(context, title: r['name']?.toString() ?? 'Referral', builder: (setS) => [
      Text('Status', style: AppleTheme.footnote(context)),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (var i = 0; i < 5; i++) GestureDetector(
          onTap: () => setS(() => status = i),
          child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: status == i ? Palette.of(context).accent : Palette.of(context).card2, borderRadius: BorderRadius.zero),
            child: Text(const ['New', 'Contacted', 'Enrolled', 'Rewarded', 'Rejected'][i], style: TextStyle(fontSize: 12, color: status == i ? Colors.white : Palette.of(context).label)))),
      ]),
      const SizedBox(height: 10),
      sheetField(reward, 'Reward (₹)', CupertinoIcons.money_dollar, keyboard: TextInputType.number),
    ], onSubmit: () async {
      try {
        await widget.auth.apiPost('/api/v1/manage/ambassadors/referrals/$id/status', {
          'status': const ['new', 'contacted', 'enrolled', 'rewarded', 'rejected'][status],
          'reward_paise': ((double.tryParse(reward.text.trim()) ?? 0) * 100).round(),
        });
        return null;
      } on ApiException catch (e) { return e.message; }
    });
    if (ok == true) { _toast('Updated'); _load(); }
  }
}

// ===========================================================================
// Ambassador — own dashboard + referrals
// ===========================================================================

class _AmbassadorDashboard extends StatefulWidget {
  const _AmbassadorDashboard({required this.auth});
  final AuthService auth;
  @override
  State<_AmbassadorDashboard> createState() => _AmbassadorDashboardState();
}

class _AmbassadorDashboardState extends State<_AmbassadorDashboard> {
  bool _loading = true;
  Map<String, dynamic> _me = {};
  List<dynamic> _refs = [];
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try {
      _me = ApiClient.decode(await widget.auth.apiGet('/api/v1/ambassador/me'));
      _refs = (ApiClient.decode(await widget.auth.apiGet('/api/v1/ambassador/referrals'))['referrals'] as List?) ?? [];
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _refer,
        backgroundColor: Palette.of(context).accent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        icon: const Icon(CupertinoIcons.add, color: Colors.white),
        label: const Text('Refer someone', style: TextStyle(color: Colors.white)),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: EdgeInsets.fromLTRB(hp, 18, hp, 100), children: [
          Text('Ambassador', style: AppleTheme.largeTitle(context)),
          const SizedBox(height: 12),
          // Referral code card.
          AppleCard(child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Your referral code', style: AppleTheme.footnote(context)),
              Text('${_me['code'] ?? '—'}', style: AppleTheme.title2(context).copyWith(letterSpacing: 2)),
            ])),
            Icon(CupertinoIcons.gift_fill, color: Palette.of(context).accent, size: 28),
          ])),
          const SizedBox(height: 12),
          Row(children: [stat('Referrals', '${_me['referrals'] ?? 0}'), const SizedBox(width: 12), stat('Converted', '${_me['converted'] ?? 0}')]),
          const SizedBox(height: 12),
          Row(children: [stat('Earned', _money((_me['earned'] as num?) ?? 0)), const SizedBox(width: 12), stat('Pending', _money((_me['pending_reward'] as num?) ?? 0))]),
          const SizedBox(height: 20),
          Text('My referrals', style: AppleTheme.headline(context)),
          const SizedBox(height: 8),
          if (_refs.isEmpty)
            AppleCard(child: Text('No referrals yet — tap "Refer someone" to add your first.', style: AppleTheme.footnote(context)))
          else
            ..._refs.map((r) => _row(r as Map<String, dynamic>)),
        ]),
      ),
    );
  }

  Widget _row(Map<String, dynamic> r) {
    final status = r['status']?.toString() ?? 'new';
    final c = _refColor(status);
    return Padding(padding: const EdgeInsets.only(bottom: 10), child: AppleCard(child: Row(children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(r['name']?.toString() ?? '', style: AppleTheme.headline(context)),
        Text([r['phone'], r['email']].where((x) => (x?.toString() ?? '').isNotEmpty).join(' · '), style: AppleTheme.footnote(context)),
      ])),
      Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: c.withOpacity(0.14), borderRadius: BorderRadius.zero), child: Text(status, style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w700))),
    ])));
  }

  Future<void> _refer() async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final email = TextEditingController();
    final ok = await showFormSheet(context, title: 'Refer someone', builder: (setS) => [
      sheetField(name, 'Their name', CupertinoIcons.person),
      const SizedBox(height: 10),
      sheetField(phone, 'Phone', CupertinoIcons.phone, keyboard: TextInputType.phone),
      const SizedBox(height: 10),
      sheetField(email, 'Email', CupertinoIcons.mail, keyboard: TextInputType.emailAddress),
    ], onSubmit: () async {
      if (name.text.trim().isEmpty) return 'Name required';
      try {
        await widget.auth.apiPost('/api/v1/ambassador/referrals', {'name': name.text.trim(), 'phone': phone.text.trim(), 'email': email.text.trim()});
        return null;
      } on ApiException catch (e) { return e.message; }
    });
    if (ok == true) { _toast('Referral submitted'); _load(); }
  }
}
