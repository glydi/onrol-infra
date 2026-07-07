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

/// Standalone Accounts & Administration portal — served on the `accounts.`
/// subdomain. Admins run the books + approve expenses + manage staff;
/// employees file their own expenses.
class AccountsPortalScreen extends StatelessWidget {
  const AccountsPortalScreen({super.key, required this.auth});
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
    if (!isAdmin && !isEmployee) return _denied(context);

    if (isAdmin) {
      return AppShell(
        auth: auth,
        onSignOut: () => _logout(context),
        destinations: const [
          NavDest(CupertinoIcons.book_fill, 'Ledger'),
          NavDest(CupertinoIcons.creditcard_fill, 'Expenses'),
          NavDest(CupertinoIcons.person_2_fill, 'Staff'),
          NavDest(CupertinoIcons.person_fill, 'Profile'),
        ],
        pages: [
          _LedgerTab(auth: auth),
          _AdminExpenses(auth: auth),
          _StaffTab(auth: auth),
          ProfileView(auth: auth, onSignOut: () => _logout(context)),
        ],
      );
    }
    return AppShell(
      auth: auth,
      onSignOut: () => _logout(context),
      destinations: const [
        NavDest(CupertinoIcons.creditcard_fill, 'My Expenses'),
        NavDest(CupertinoIcons.person_fill, 'Profile'),
      ],
      pages: [
        _MyExpenses(auth: auth),
        ProfileView(auth: auth, onSignOut: () => _logout(context)),
      ],
    );
  }

  Widget _denied(BuildContext context) => Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(CupertinoIcons.lock_fill, size: 48, color: CupertinoColors.systemGrey),
            const SizedBox(height: 16),
            Text('Staff only', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('This portal is for employees and admins.'),
            const SizedBox(height: 24),
            TextButton(onPressed: () => _logout(context), child: const Text('Sign out')),
          ]),
        ),
      );
}

/// True when served from the Accounts subdomain (accounts.*).
bool isAccountsHost() {
  final h = Uri.base.host;
  return h == 'accounts' || h.startsWith('accounts.');
}

String _money(num paise) {
  final neg = paise < 0;
  final v = paise.abs() / 100;
  String s;
  if (v >= 100000) {
    s = '₹${(v / 100000).toStringAsFixed(2)}L';
  } else if (v >= 1000) {
    s = '₹${(v / 1000).toStringAsFixed(1)}K';
  } else {
    s = '₹${v.toStringAsFixed(0)}';
  }
  return neg ? '-$s' : s;
}

Color _expColor(String s) => switch (s) {
      'paid' => AppleColors.green,
      'approved' => AppleColors.blue,
      'rejected' => AppleColors.red,
      _ => AppleColors.orange, // pending
    };

String _fmtDate(dynamic v) {
  final d = v == null ? null : DateTime.tryParse(v.toString())?.toLocal();
  if (d == null) return '—';
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${m[d.month - 1]} ${d.year}';
}

Widget _expenseCard(BuildContext context, Map<String, dynamic> e, {Widget? trailing, VoidCallback? onTap}) {
  final status = e['status']?.toString() ?? 'pending';
  final c = _expColor(status);
  final total = ((e['amount'] as num?) ?? 0) + ((e['gst_amount'] as num?) ?? 0);
  final sub = [e['category'], e['vendor'], if ((e['by']?.toString() ?? '').isNotEmpty) e['by']].where((x) => (x?.toString() ?? '').isNotEmpty).join(' · ');
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AppleCard(child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(sub.isEmpty ? 'Expense' : sub, style: AppleTheme.headline(context)),
          Text(_fmtDate(e['expense_date']), style: AppleTheme.footnote(context)),
        ])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(_money(total), style: AppleTheme.headline(context)),
          Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: c.withOpacity(0.14), borderRadius: BorderRadius.zero), child: Text(status, style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w700))),
        ]),
        if (trailing != null) ...[const SizedBox(width: 8), trailing],
      ])),
    ),
  );
}

Widget _accFab(VoidCallback onTap, String label) => Builder(builder: (context) => FloatingActionButton.extended(
      onPressed: onTap,
      backgroundColor: Palette.of(context).accent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      icon: const Icon(CupertinoIcons.add, color: Colors.white),
      label: Text(label, style: const TextStyle(color: Colors.white)),
    ));

// Shared expense form. Returns the payload map, or null if cancelled.
Future<bool> _expenseForm(BuildContext context, AuthService auth, String path) async {
  final vendor = TextEditingController();
  final category = TextEditingController();
  final amount = TextEditingController();
  final gst = TextEditingController();
  final notes = TextEditingController();
  final ok = await showFormSheet(context, title: 'New Expense', builder: (setS) => [
    sheetField(vendor, 'Vendor / paid to', CupertinoIcons.building_2_fill),
    const SizedBox(height: 10),
    sheetField(category, 'Category (e.g. Travel)', CupertinoIcons.tag),
    const SizedBox(height: 10),
    sheetField(amount, 'Amount (₹)', CupertinoIcons.money_dollar, keyboard: TextInputType.number),
    const SizedBox(height: 10),
    sheetField(gst, 'GST (₹, optional)', CupertinoIcons.percent, keyboard: TextInputType.number),
    const SizedBox(height: 10),
    sheetField(notes, 'Notes', CupertinoIcons.text_alignleft),
  ], onSubmit: () async {
    final amt = double.tryParse(amount.text.trim()) ?? 0;
    if (amt <= 0) return 'Enter an amount';
    try {
      await auth.apiPost(path, {
        'vendor': vendor.text.trim(), 'category': category.text.trim(),
        'amount': (amt * 100).round(), 'gst_amount': ((double.tryParse(gst.text.trim()) ?? 0) * 100).round(),
        'notes': notes.text.trim(),
      });
      return null;
    } on ApiException catch (e) { return e.message; }
  });
  return ok == true;
}

// ===========================================================================
// Admin — ledger
// ===========================================================================

class _LedgerTab extends StatefulWidget {
  const _LedgerTab({required this.auth});
  final AuthService auth;
  @override
  State<_LedgerTab> createState() => _LedgerTabState();
}

class _LedgerTabState extends State<_LedgerTab> {
  bool _loading = true;
  Map<String, dynamic> _data = {};
  List<dynamic> get _entries => (_data['entries'] as List?) ?? [];
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { _data = ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/accounts/ledger')); } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }
  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    Widget stat(String label, num v, Color col) => Expanded(child: AppleCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_money(v), style: AppleTheme.title2(context).copyWith(color: col)),
      Text(label, style: AppleTheme.footnote(context)),
    ])));
    return Scaffold(
      backgroundColor: Palette.of(context).bg,
      floatingActionButton: _accFab(_add, 'Entry'),
      body: RefreshIndicator(onRefresh: _load, child: ListView(padding: EdgeInsets.fromLTRB(hp, 18, hp, 100), children: [
        Text('Ledger', style: AppleTheme.largeTitle(context)),
        const SizedBox(height: 12),
        Row(children: [
          stat('Income', (_data['income'] as num?) ?? 0, AppleColors.green),
          const SizedBox(width: 12),
          stat('Expense', (_data['expense'] as num?) ?? 0, AppleColors.red),
        ]),
        const SizedBox(height: 12),
        AppleCard(child: Row(children: [
          Text('Balance', style: AppleTheme.headline(context)),
          const Spacer(),
          Text(_money((_data['balance'] as num?) ?? 0), style: AppleTheme.title2(context).copyWith(color: ((_data['balance'] as num?) ?? 0) < 0 ? AppleColors.red : AppleColors.green)),
        ])),
        const SizedBox(height: 20),
        Text('Entries', style: AppleTheme.headline(context)),
        const SizedBox(height: 8),
        if (_entries.isEmpty) AppleCard(child: Text('No entries yet.', style: AppleTheme.footnote(context)))
        else ..._entries.map((e) => _row(e as Map<String, dynamic>)),
      ])),
    );
  }

  Widget _row(Map<String, dynamic> e) {
    final income = e['kind'] == 'income';
    final col = income ? AppleColors.green : AppleColors.red;
    return Padding(padding: const EdgeInsets.only(bottom: 10), child: AppleCard(child: Row(children: [
      Icon(income ? CupertinoIcons.arrow_down_circle_fill : CupertinoIcons.arrow_up_circle_fill, color: col),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(e['description']?.toString().isEmpty ?? true ? (e['category']?.toString() ?? 'Entry') : e['description'].toString(), style: AppleTheme.headline(context)),
        Text('${e['category']} · ${_fmtDate(e['entry_date'])}', style: AppleTheme.footnote(context)),
      ])),
      Text('${income ? '+' : '-'}${_money((e['amount'] as num?) ?? 0)}', style: AppleTheme.headline(context).copyWith(color: col)),
      const SizedBox(width: 8),
      GestureDetector(onTap: () async { await widget.auth.apiDelete('/api/v1/manage/accounts/ledger/${e['id']}'); _load(); }, child: const Icon(CupertinoIcons.trash, size: 18, color: AppleColors.red)),
    ])));
  }

  Future<void> _add() async {
    final category = TextEditingController();
    final amount = TextEditingController();
    final desc = TextEditingController();
    int kind = 1; // income, expense
    final ok = await showFormSheet(context, title: 'Ledger Entry', builder: (setS) => [
      AppleSegmented(labels: const ['Income', 'Expense'], selected: kind, onChanged: (i) => setS(() => kind = i)),
      const SizedBox(height: 10),
      sheetField(category, 'Category', CupertinoIcons.tag),
      const SizedBox(height: 10),
      sheetField(amount, 'Amount (₹)', CupertinoIcons.money_dollar, keyboard: TextInputType.number),
      const SizedBox(height: 10),
      sheetField(desc, 'Description', CupertinoIcons.text_alignleft),
    ], onSubmit: () async {
      final amt = double.tryParse(amount.text.trim()) ?? 0;
      if (amt <= 0) return 'Enter an amount';
      try {
        await widget.auth.apiPost('/api/v1/manage/accounts/ledger', {
          'kind': kind == 0 ? 'income' : 'expense', 'category': category.text.trim(),
          'amount': (amt * 100).round(), 'description': desc.text.trim(),
        });
        return null;
      } on ApiException catch (e) { return e.message; }
    });
    if (ok == true) { _toast('Entry added'); _load(); }
  }
}

// ===========================================================================
// Admin — expenses (approve / pay)
// ===========================================================================

class _AdminExpenses extends StatefulWidget {
  const _AdminExpenses({required this.auth});
  final AuthService auth;
  @override
  State<_AdminExpenses> createState() => _AdminExpensesState();
}

class _AdminExpensesState extends State<_AdminExpenses> {
  bool _loading = true;
  List<dynamic> _items = [];
  int _pending = 0;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try {
      final d = ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/accounts/expenses'));
      _items = (d['expenses'] as List?) ?? [];
      _pending = ((d['pending'] as num?) ?? 0).toInt();
    } catch (_) {}
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
        Text('Expenses', style: AppleTheme.largeTitle(context)),
        Text('$_pending awaiting approval', style: AppleTheme.subhead(context)),
        const SizedBox(height: 14),
        if (_items.isEmpty) AppleCard(child: Text('No expenses filed.', style: AppleTheme.footnote(context)))
        else ..._items.map((e) => _expenseCard(context, e as Map<String, dynamic>, onTap: () => _manage(e))),
      ])),
    );
  }

  Future<void> _manage(Map<String, dynamic> e) async {
    final id = e['id'].toString();
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final p = Palette.of(ctx);
        return Container(
          margin: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.zero),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 12),
            Text('Set status', style: AppleTheme.headline(ctx)),
            const SizedBox(height: 8),
            for (final s in const ['approved', 'paid', 'rejected', 'pending'])
              ListTile(leading: Icon(CupertinoIcons.circle, color: _expColor(s)), title: Text(s, style: AppleTheme.body(ctx)), onTap: () => Navigator.pop(ctx, s)),
            const SizedBox(height: 8),
          ]),
        );
      },
    );
    if (picked == null) return;
    try {
      await widget.auth.apiPost('/api/v1/manage/accounts/expenses/$id/status', {'status': picked});
      _toast('Marked $picked');
      _load();
    } catch (_) { _toast('Could not update'); }
  }
}

// ===========================================================================
// Admin — staff
// ===========================================================================

class _StaffTab extends StatefulWidget {
  const _StaffTab({required this.auth});
  final AuthService auth;
  @override
  State<_StaffTab> createState() => _StaffTabState();
}

class _StaffTabState extends State<_StaffTab> {
  bool _loading = true;
  List<dynamic> _items = [];
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { _items = (ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/accounts/staff'))['employees'] as List?) ?? []; } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }
  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    return Scaffold(
      backgroundColor: Palette.of(context).bg,
      floatingActionButton: _accFab(_add, 'New Employee'),
      body: RefreshIndicator(onRefresh: _load, child: ListView(padding: EdgeInsets.fromLTRB(hp, 18, hp, 100), children: [
        Text('Staff', style: AppleTheme.largeTitle(context)),
        Text('${_items.length} employees', style: AppleTheme.subhead(context)),
        const SizedBox(height: 14),
        if (_items.isEmpty) AppleCard(child: Text('No employees yet. Add one — they get a login to this portal.', style: AppleTheme.footnote(context)))
        else ..._items.map((u) => Padding(padding: const EdgeInsets.only(bottom: 12), child: AppleCard(child: Row(children: [
          Avatar(name: u['full_name']?.toString() ?? '?', size: 40),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(u['full_name']?.toString() ?? '', style: AppleTheme.headline(context)),
            Text([u['email'], u['phone']].where((x) => (x?.toString() ?? '').isNotEmpty).join(' · '), style: AppleTheme.footnote(context)),
          ])),
          if (u['is_active'] == false) const Icon(CupertinoIcons.nosign, color: AppleColors.red, size: 18),
        ])))),
      ])),
    );
  }

  Future<void> _add() async {
    final name = TextEditingController();
    final email = TextEditingController();
    final phone = TextEditingController();
    final pass = TextEditingController();
    final ok = await showFormSheet(context, title: 'New Employee', builder: (setS) => [
      sheetField(name, 'Full name', CupertinoIcons.person),
      const SizedBox(height: 10),
      sheetField(email, 'Email (login)', CupertinoIcons.mail, keyboard: TextInputType.emailAddress),
      const SizedBox(height: 10),
      sheetField(phone, 'Phone', CupertinoIcons.phone, keyboard: TextInputType.phone),
      const SizedBox(height: 10),
      sheetField(pass, 'Temp password', CupertinoIcons.lock),
    ], onSubmit: () async {
      if (name.text.trim().isEmpty || email.text.trim().isEmpty || pass.text.isEmpty) return 'Name, email and password required';
      try {
        await widget.auth.apiPost('/api/v1/manage/accounts/staff', {'full_name': name.text.trim(), 'email': email.text.trim(), 'phone': phone.text.trim(), 'password': pass.text});
        return null;
      } on ApiException catch (e) { return e.message; }
    });
    if (ok == true) { _toast('Employee created'); _load(); }
  }
}

// ===========================================================================
// Employee — my expenses
// ===========================================================================

class _MyExpenses extends StatefulWidget {
  const _MyExpenses({required this.auth});
  final AuthService auth;
  @override
  State<_MyExpenses> createState() => _MyExpensesState();
}

class _MyExpensesState extends State<_MyExpenses> {
  bool _loading = true;
  List<dynamic> _items = [];
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { _items = (ApiClient.decode(await widget.auth.apiGet('/api/v1/accounts/expenses'))['expenses'] as List?) ?? []; } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }
  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    return Scaffold(
      backgroundColor: Palette.of(context).bg,
      floatingActionButton: _accFab(() async {
        if (await _expenseForm(context, widget.auth, '/api/v1/accounts/expenses')) { _toast('Submitted'); _load(); }
      }, 'File Expense'),
      body: RefreshIndicator(onRefresh: _load, child: ListView(padding: EdgeInsets.fromLTRB(hp, 18, hp, 100), children: [
        Text('My Expenses', style: AppleTheme.largeTitle(context)),
        Text('${_items.length} filed', style: AppleTheme.subhead(context)),
        const SizedBox(height: 14),
        if (_items.isEmpty) AppleCard(child: Text('No expenses yet — tap "File Expense" to submit one for approval.', style: AppleTheme.footnote(context)))
        else ..._items.map((e) => _expenseCard(context, e as Map<String, dynamic>)),
      ])),
    );
  }
}
