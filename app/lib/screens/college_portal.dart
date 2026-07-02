import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import '../widgets/app_shell.dart';
import '../widgets/profile_view.dart';
import '../widgets/ui.dart';
import 'login_screen.dart';

/// Standalone College Partner portal — served on the `college.` subdomain.
/// Admins + employees manage partner colleges, cohorts, MOUs and placements.
class CollegePortalScreen extends StatelessWidget {
  const CollegePortalScreen({super.key, required this.auth});
  final AuthService auth;

  Future<void> _logout(BuildContext context) async {
    await auth.logout();
    if (!context.mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => LoginScreen(auth: auth)));
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = auth.user?.isAdmin ?? false;
    final isEmployee = auth.user?.role == 'employee';
    if (!isAdmin && !isEmployee) {
      return Scaffold(
        body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(CupertinoIcons.lock_fill, size: 48, color: CupertinoColors.systemGrey),
          const SizedBox(height: 16),
          Text('Staff only', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text('This portal is for employees and admins.'),
          const SizedBox(height: 24),
          TextButton(onPressed: () => _logout(context), child: const Text('Sign out')),
        ])),
      );
    }
    return AppShell(
      auth: auth,
      onSignOut: () => _logout(context),
      destinations: const [
        NavDest(CupertinoIcons.building_2_fill, 'Colleges'),
        NavDest(CupertinoIcons.person_fill, 'Profile'),
      ],
      pages: [
        _CollegesTab(auth: auth),
        ProfileView(auth: auth, onSignOut: () => _logout(context)),
      ],
    );
  }
}

/// True when served from the College subdomain (college.*).
bool isCollegeHost() {
  final h = Uri.base.host;
  return h == 'college' || h.startsWith('college.');
}

Color _mouColor(String s) => switch (s) {
      'signed' => AppleColors.green,
      'draft' => AppleColors.orange,
      'expired' => AppleColors.red,
      _ => const Color(0xFF8E8E93),
    };

// ===========================================================================
// Colleges list
// ===========================================================================

class _CollegesTab extends StatefulWidget {
  const _CollegesTab({required this.auth});
  final AuthService auth;
  @override
  State<_CollegesTab> createState() => _CollegesTabState();
}

class _CollegesTabState extends State<_CollegesTab> {
  bool _loading = true;
  List<dynamic> _items = [];
  Map<String, dynamic> _summary = {};
  final _search = TextEditingController();

  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try {
      final q = _search.text.trim().isEmpty ? '' : '?q=${Uri.encodeComponent(_search.text.trim())}';
      _items = (ApiClient.decode(await widget.auth.apiGet('/api/v1/college/colleges$q'))['colleges'] as List?) ?? [];
      _summary = ApiClient.decode(await widget.auth.apiGet('/api/v1/college/summary'));
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }
  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    Widget stat(String label, num v) => Expanded(child: AppleCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('$v', style: AppleTheme.title2(context)),
      Text(label, style: AppleTheme.footnote(context)),
    ])));
    return Scaffold(
      backgroundColor: Palette.of(context).bg,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        backgroundColor: Palette.of(context).accent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        icon: const Icon(CupertinoIcons.add, color: Colors.white),
        label: const Text('Add College', style: TextStyle(color: Colors.white)),
      ),
      body: RefreshIndicator(onRefresh: _load, child: ListView(padding: EdgeInsets.fromLTRB(hp, 18, hp, 100), children: [
        Text('College Partners', style: AppleTheme.largeTitle(context)),
        const SizedBox(height: 12),
        Row(children: [stat('Colleges', (_summary['colleges'] as num?) ?? 0), const SizedBox(width: 12), stat('MOUs signed', (_summary['signed'] as num?) ?? 0)]),
        const SizedBox(height: 12),
        Row(children: [stat('Students', (_summary['students'] as num?) ?? 0), const SizedBox(width: 12), stat('Placed', (_summary['placed'] as num?) ?? 0)]),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          decoration: BoxDecoration(color: Palette.of(context).card2, borderRadius: BorderRadius.zero),
          child: Row(children: [
            Icon(CupertinoIcons.search, size: 18, color: Palette.of(context).secondary),
            const SizedBox(width: 8),
            Expanded(child: CupertinoTextField(controller: _search, placeholder: 'Search college or city', decoration: const BoxDecoration(), onSubmitted: (_) => _load())),
          ]),
        ),
        const SizedBox(height: 16),
        if (_items.isEmpty) AppleCard(child: Text('No colleges yet. Add a partner college below.', style: AppleTheme.footnote(context)))
        else ..._items.map((c) => _card(c as Map<String, dynamic>)),
      ])),
    );
  }

  Widget _card(Map<String, dynamic> col) {
    final mou = col['mou_status']?.toString() ?? 'none';
    final mc = _mouColor(mou);
    final sub = [col['city'], '${col['students']} students', '${col['placed']} placed'].where((x) => (x?.toString() ?? '').isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CollegeDetailScreen(auth: widget.auth, college: col))).then((_) => _load()),
        behavior: HitTestBehavior.opaque,
        child: AppleCard(child: Row(children: [
          Container(width: 40, height: 40, alignment: Alignment.center, decoration: BoxDecoration(color: mc.withOpacity(0.14), borderRadius: BorderRadius.zero), child: Icon(CupertinoIcons.building_2_fill, color: mc, size: 20)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(col['name']?.toString() ?? 'College', style: AppleTheme.headline(context)),
            Text(sub, style: AppleTheme.footnote(context)),
          ])),
          Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: mc.withOpacity(0.14), borderRadius: BorderRadius.zero), child: Text(mou == 'none' ? 'no MOU' : mou, style: TextStyle(fontSize: 11, color: mc, fontWeight: FontWeight.w700))),
        ])),
      ),
    );
  }

  Future<void> _add() async {
    final name = TextEditingController();
    final person = TextEditingController();
    final phone = TextEditingController();
    final city = TextEditingController();
    int mou = 0;
    const mouOpts = ['none', 'draft', 'signed', 'expired'];
    final ok = await showFormSheet(context, title: 'Add College', builder: (setS) => [
      sheetField(name, 'College name', CupertinoIcons.building_2_fill),
      const SizedBox(height: 10),
      sheetField(person, 'Contact person', CupertinoIcons.person),
      const SizedBox(height: 10),
      sheetField(phone, 'Phone', CupertinoIcons.phone, keyboard: TextInputType.phone),
      const SizedBox(height: 10),
      sheetField(city, 'City', CupertinoIcons.location),
      const SizedBox(height: 10),
      AppleSegmented(labels: const ['No MOU', 'Draft', 'Signed', 'Expired'], selected: mou, onChanged: (i) => setS(() => mou = i)),
    ], onSubmit: () async {
      if (name.text.trim().isEmpty) return 'Name required';
      try {
        await widget.auth.apiPost('/api/v1/college/colleges', {
          'name': name.text.trim(), 'contact_person': person.text.trim(),
          'phone': phone.text.trim(), 'city': city.text.trim(), 'mou_status': mouOpts[mou],
        });
        return null;
      } on ApiException catch (e) { return e.message; }
    });
    if (ok == true) { _toast('College added'); _load(); }
  }
}

// ===========================================================================
// College detail — info + MOU + cohorts
// ===========================================================================

class CollegeDetailScreen extends StatefulWidget {
  const CollegeDetailScreen({super.key, required this.auth, required this.college});
  final AuthService auth;
  final Map<String, dynamic> college;
  @override
  State<CollegeDetailScreen> createState() => _CollegeDetailScreenState();
}

class _CollegeDetailScreenState extends State<CollegeDetailScreen> {
  late Map<String, dynamic> _c;
  List<dynamic> _cohorts = [];
  bool _loading = true;
  String get _id => _c['id'].toString();

  @override
  void initState() { super.initState(); _c = Map<String, dynamic>.from(widget.college); _load(); }
  Future<void> _load() async {
    try { _cohorts = (ApiClient.decode(await widget.auth.apiGet('/api/v1/college/colleges/$_id/cohorts'))['cohorts'] as List?) ?? []; } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }
  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  Future<void> _setMou() async {
    const opts = ['none', 'draft', 'signed', 'expired'];
    final picked = await showModalBottomSheet<String>(
      context: context, backgroundColor: Colors.transparent,
      builder: (ctx) {
        final p = Palette.of(ctx);
        return Container(margin: const EdgeInsets.all(10), decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.zero),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 12), Text('MOU status', style: AppleTheme.headline(ctx)), const SizedBox(height: 8),
            for (final s in opts) ListTile(leading: Icon(CupertinoIcons.circle, color: _mouColor(s)), title: Text(s, style: AppleTheme.body(ctx)), onTap: () => Navigator.pop(ctx, s)),
            const SizedBox(height: 8),
          ]));
      },
    );
    if (picked == null) return;
    await widget.auth.apiPatch('/api/v1/college/colleges/$_id', {'mou_status': picked});
    setState(() => _c['mou_status'] = picked);
    _toast('MOU: $picked');
  }

  @override
  Widget build(BuildContext context) {
    final mou = _c['mou_status']?.toString() ?? 'none';
    final mc = _mouColor(mou);
    return Scaffold(
      backgroundColor: Palette.of(context).bg,
      appBar: AppBar(title: Text(_c['name']?.toString() ?? 'College')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addCohort,
        backgroundColor: Palette.of(context).accent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        icon: const Icon(CupertinoIcons.add, color: Colors.white),
        label: const Text('Add Cohort', style: TextStyle(color: Colors.white)),
      ),
      body: _loading ? const Center(child: CupertinoActivityIndicator()) : ListView(padding: const EdgeInsets.fromLTRB(18, 12, 18, 100), children: [
        AppleCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(_c['name']?.toString() ?? '', style: AppleTheme.title2(context))),
            GestureDetector(onTap: _setMou, child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(color: mc.withOpacity(0.14), borderRadius: BorderRadius.zero),
              child: Row(mainAxisSize: MainAxisSize.min, children: [Text(mou == 'none' ? 'no MOU' : mou, style: TextStyle(fontSize: 12, color: mc, fontWeight: FontWeight.w700)), const SizedBox(width: 4), Icon(CupertinoIcons.chevron_down, size: 12, color: mc)]))),
          ]),
          const SizedBox(height: 8),
          if ((_c['contact_person']?.toString() ?? '').isNotEmpty) _kv(CupertinoIcons.person, _c['contact_person'].toString()),
          if ((_c['phone']?.toString() ?? '').isNotEmpty) _kv(CupertinoIcons.phone, _c['phone'].toString()),
          if ((_c['city']?.toString() ?? '').isNotEmpty) _kv(CupertinoIcons.location, _c['city'].toString()),
        ])),
        const SizedBox(height: 20),
        Text('Cohorts (${_cohorts.length})', style: AppleTheme.headline(context)),
        const SizedBox(height: 8),
        if (_cohorts.isEmpty) AppleCard(child: Text('No cohorts yet — add an intake batch with student + placement counts.', style: AppleTheme.footnote(context)))
        else ..._cohorts.map((c) => _cohortRow(c as Map<String, dynamic>)),
      ]),
    );
  }

  Widget _kv(IconData icon, String v) => Padding(padding: const EdgeInsets.only(top: 4), child: Row(children: [
    Icon(icon, size: 15, color: Palette.of(context).secondary), const SizedBox(width: 8), Expanded(child: Text(v, style: AppleTheme.body(context))),
  ]));

  Widget _cohortRow(Map<String, dynamic> ch) {
    final students = (ch['students'] as num?)?.toInt() ?? 0;
    final placed = (ch['placed'] as num?)?.toInt() ?? 0;
    final pct = students > 0 ? (placed / students) : 0.0;
    return Padding(padding: const EdgeInsets.only(bottom: 10), child: GestureDetector(
      onTap: () => _editCohort(ch),
      behavior: HitTestBehavior.opaque,
      child: AppleCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('${ch['name']}${ch['year'] != null ? ' · ${ch['year']}' : ''}', style: AppleTheme.headline(context))),
          Text('$placed/$students placed', style: AppleTheme.footnote(context)),
        ]),
        const SizedBox(height: 8),
        ClipRRect(borderRadius: BorderRadius.zero, child: LinearProgressIndicator(value: pct.clamp(0, 1), minHeight: 6, backgroundColor: Palette.of(context).card2, color: AppleColors.green)),
      ])),
    ));
  }

  Future<void> _addCohort() async {
    final name = TextEditingController();
    final year = TextEditingController();
    final students = TextEditingController();
    final placed = TextEditingController(text: '0');
    final ok = await showFormSheet(context, title: 'Add Cohort', builder: (setS) => [
      sheetField(name, 'Cohort name (e.g. CS 2025)', CupertinoIcons.group),
      const SizedBox(height: 10),
      sheetField(year, 'Year', CupertinoIcons.calendar, keyboard: TextInputType.number),
      const SizedBox(height: 10),
      sheetField(students, 'Students', CupertinoIcons.person_2, keyboard: TextInputType.number),
      const SizedBox(height: 10),
      sheetField(placed, 'Placed', CupertinoIcons.checkmark_seal, keyboard: TextInputType.number),
    ], onSubmit: () async {
      if (name.text.trim().isEmpty) return 'Name required';
      try {
        await widget.auth.apiPost('/api/v1/college/colleges/$_id/cohorts', {
          'name': name.text.trim(), 'year': int.tryParse(year.text.trim()),
          'students': int.tryParse(students.text.trim()) ?? 0, 'placed': int.tryParse(placed.text.trim()) ?? 0,
        });
        return null;
      } on ApiException catch (e) { return e.message; }
    });
    if (ok == true) { _toast('Cohort added'); _load(); }
  }

  Future<void> _editCohort(Map<String, dynamic> ch) async {
    final students = TextEditingController(text: '${ch['students'] ?? 0}');
    final placed = TextEditingController(text: '${ch['placed'] ?? 0}');
    int status = ['planned', 'active', 'completed'].indexOf(ch['status']?.toString() ?? 'active');
    if (status < 0) status = 1;
    final ok = await showFormSheet(context, title: ch['name']?.toString() ?? 'Cohort', builder: (setS) => [
      sheetField(students, 'Students', CupertinoIcons.person_2, keyboard: TextInputType.number),
      const SizedBox(height: 10),
      sheetField(placed, 'Placed', CupertinoIcons.checkmark_seal, keyboard: TextInputType.number),
      const SizedBox(height: 10),
      AppleSegmented(labels: const ['Planned', 'Active', 'Completed'], selected: status, onChanged: (i) => setS(() => status = i)),
      const SizedBox(height: 14),
      GestureDetector(onTap: () async { await widget.auth.apiDelete('/api/v1/college/cohorts/${ch['id']}'); if (context.mounted) Navigator.pop(context, true); },
        child: Text('Delete cohort', style: TextStyle(color: AppleColors.red, fontWeight: FontWeight.w600))),
    ], onSubmit: () async {
      try {
        await widget.auth.apiPatch('/api/v1/college/cohorts/${ch['id']}', {
          'students': int.tryParse(students.text.trim()) ?? 0, 'placed': int.tryParse(placed.text.trim()) ?? 0,
          'status': const ['planned', 'active', 'completed'][status],
        });
        return null;
      } on ApiException catch (e) { return e.message; }
    });
    if (ok == true) { _toast('Saved'); _load(); }
  }
}
