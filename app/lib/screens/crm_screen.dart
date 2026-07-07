import 'package:flutter/cupertino.dart' hide Text;
import 'package:flutter/material.dart' hide Text;
import 'package:onrol_app/widgets/upper_text.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import '../widgets/ui.dart';

/// CRM hub — leads pipeline, deals, accounts (companies) and campaigns.
/// Ported from onrol-crm into the Go/Flutter stack.
class CrmScreen extends StatefulWidget {
  const CrmScreen({super.key, required this.auth});
  final AuthService auth;

  @override
  State<CrmScreen> createState() => _CrmScreenState();
}

const _leadStatuses = [
  'New Lead', 'Registered', 'Attended', 'Not Attended', 'Interested', 'Payment Pending', 'Converted',
];

Color _statusColor(String s) {
  switch (s) {
    case 'Converted':
    case 'won':
      return AppleColors.green;
    case 'Payment Pending':
      return AppleColors.orange;
    case 'Interested':
      return AppleColors.blue;
    case 'Not Attended':
    case 'lost':
      return AppleColors.red;
    case 'Attended':
    case 'Registered':
      return AppleColors.purple;
    default:
      return const Color(0xFF8E8E93);
  }
}

String _money(num paise, [String currency = 'INR']) {
  final v = paise / 100;
  final sym = currency == 'INR' ? '₹' : '$currency ';
  if (v >= 10000000) return '$sym${(v / 10000000).toStringAsFixed(2)}Cr';
  if (v >= 100000) return '$sym${(v / 100000).toStringAsFixed(2)}L';
  if (v >= 1000) return '$sym${(v / 1000).toStringAsFixed(1)}K';
  return '$sym${v.toStringAsFixed(0)}';
}

DateTime? _dt(dynamic v) => v == null ? null : DateTime.tryParse(v.toString())?.toLocal();
String _fmtD(dynamic v) {
  final d = _dt(v);
  if (d == null) return '—';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

class _CrmScreenState extends State<CrmScreen> {
  int _tab = 0;
  static const _tabLabels = [
    'Leads', 'Deals', 'Accounts', 'Campaigns', 'Invoices', 'Forms',
    'Analytics', 'Funnel', 'My Day', 'Automation', 'Surveys', 'Reviews', 'Calendar', 'Feed',
    'Tickets', 'Affiliates', 'Webhooks', 'Integrations',
  ];

  Widget _tabChip(String label, int i) {
    final on = _tab == i;
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () => setState(() => _tab = i),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(color: on ? p.accent : p.card2, borderRadius: BorderRadius.zero),
          child: Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: on ? Colors.white : p.label)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    final tabs = [
      _LeadsTab(auth: widget.auth),
      _DealsTab(auth: widget.auth),
      _AccountsTab(auth: widget.auth),
      _BroadcastsTab(auth: widget.auth),
      _InvoicesTab(auth: widget.auth),
      _FormsTab(auth: widget.auth),
      _AnalyticsTab(auth: widget.auth),
      _FunnelTab(auth: widget.auth),
      _MyDayTab(auth: widget.auth),
      _AutomationTab(auth: widget.auth),
      _SurveysTab(auth: widget.auth),
      _ReviewsTab(auth: widget.auth),
      _CalendarTab(auth: widget.auth),
      _FeedTab(auth: widget.auth),
      _TicketsTab(auth: widget.auth),
      _AffiliatesTab(auth: widget.auth),
      _WebhooksTab(auth: widget.auth),
      _IntegrationsTab(auth: widget.auth),
    ];
    return Scaffold(
      backgroundColor: Palette.of(context).bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: EdgeInsets.fromLTRB(hp, 16, hp, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('CRM', style: AppleTheme.largeTitle(context)),
              const SizedBox(height: 10),
              SizedBox(
                height: 36,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (var i = 0; i < _tabLabels.length; i++) _tabChip(_tabLabels[i], i),
                  ],
                ),
              ),
            ]),
          ),
          Expanded(child: IndexedStack(index: _tab, children: tabs)),
        ]),
      ),
    );
  }
}

// ===========================================================================
// Leads tab
// ===========================================================================

class _LeadsTab extends StatefulWidget {
  const _LeadsTab({required this.auth});
  final AuthService auth;
  @override
  State<_LeadsTab> createState() => _LeadsTabState();
}

class _LeadsTabState extends State<_LeadsTab> {
  bool _loading = true;
  List<dynamic> _leads = [];
  Map<String, dynamic> _counts = {};
  String _filter = '';
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final q = <String>[];
      if (_filter.isNotEmpty) q.add('status=${Uri.encodeComponent(_filter)}');
      if (_search.text.trim().isNotEmpty) q.add('q=${Uri.encodeComponent(_search.text.trim())}');
      final path = '/api/v1/manage/crm/leads${q.isEmpty ? '' : '?${q.join('&')}'}';
      final d = ApiClient.decode(await widget.auth.apiGet(path));
      _leads = (d['leads'] as List?) ?? [];
      _counts = (d['counts'] as Map?)?.cast<String, dynamic>() ?? {};
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  int get _total => _counts.values.fold(0, (a, b) => a + ((b as num?)?.toInt() ?? 0));

  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    return Stack(children: [
      RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.fromLTRB(hp, 8, hp, 100),
          children: [
            Text('$_total leads', style: AppleTheme.subhead(context)),
            const SizedBox(height: 10),
            _searchBar(),
            const SizedBox(height: 12),
            _pipelineChips(),
            const SizedBox(height: 16),
            if (_leads.isEmpty)
              AppleCard(child: Text('No leads${_filter.isEmpty ? ' yet' : ' in "$_filter"'}. Add one with the button below.', style: AppleTheme.footnote(context)))
            else
              ..._leads.map((l) => _leadCard(l as Map<String, dynamic>)),
          ],
        ),
      ),
      _fab(_addLead),
    ]);
  }

  Widget _searchBar() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        decoration: BoxDecoration(color: Palette.of(context).card2, borderRadius: BorderRadius.zero),
        child: Row(children: [
          Icon(CupertinoIcons.search, size: 18, color: Palette.of(context).secondary),
          const SizedBox(width: 8),
          Expanded(child: CupertinoTextField(controller: _search, placeholder: 'Search name, email or phone', decoration: const BoxDecoration(), onSubmitted: (_) => _load())),
          if (_search.text.isNotEmpty)
            GestureDetector(onTap: () { _search.clear(); _load(); }, child: Icon(CupertinoIcons.clear_circled_solid, size: 18, color: Palette.of(context).secondary)),
        ]),
      );

  Widget _pipelineChips() {
    Widget chip(String label, String value, int count) {
      final on = _filter == value;
      final p = Palette.of(context);
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: GestureDetector(
          onTap: () { setState(() => _filter = value); _load(); },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(color: on ? p.accent : p.card2, borderRadius: BorderRadius.zero),
            child: Text('$label${count > 0 ? '  $count' : ''}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: on ? Colors.white : p.label)),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [chip('All', '', _total), for (final s in _leadStatuses) chip(s, s, ((_counts[s] as num?) ?? 0).toInt())]),
    );
  }

  Widget _leadCard(Map<String, dynamic> l) {
    final status = l['status']?.toString() ?? 'New Lead';
    final sc = _statusColor(status);
    final contact = [l['phone'], l['email']].where((x) => (x?.toString() ?? '').isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => LeadDetailScreen(auth: widget.auth, lead: l))).then((_) => _load()),
        behavior: HitTestBehavior.opaque,
        child: AppleCard(
          child: Row(children: [
            Avatar(name: l['name']?.toString() ?? '?', size: 40),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l['name']?.toString() ?? 'Lead', style: AppleTheme.headline(context)),
              if (contact.isNotEmpty) Text(contact, style: AppleTheme.footnote(context), maxLines: 1, overflow: TextOverflow.ellipsis),
            ])),
            const SizedBox(width: 8),
            Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: sc.withOpacity(0.14), borderRadius: BorderRadius.zero),
                child: Text(status, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: sc))),
          ]),
        ),
      ),
    );
  }

  Future<void> _addLead() async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final email = TextEditingController();
    final source = TextEditingController();
    final ok = await showFormSheet(context, title: 'Add Lead', builder: (setS) => [
      sheetField(name, 'Full name', CupertinoIcons.person),
      const SizedBox(height: 10),
      sheetField(phone, 'Phone', CupertinoIcons.phone, keyboard: TextInputType.phone),
      const SizedBox(height: 10),
      sheetField(email, 'Email', CupertinoIcons.mail, keyboard: TextInputType.emailAddress),
      const SizedBox(height: 10),
      sheetField(source, 'Source (e.g. Webinar, Referral)', CupertinoIcons.tag),
    ], onSubmit: () async {
      if (name.text.trim().isEmpty) return 'Name required';
      try {
        await widget.auth.apiPost('/api/v1/manage/crm/leads', {'name': name.text.trim(), 'phone': phone.text.trim(), 'email': email.text.trim(), 'source': source.text.trim()});
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) { _toast('Lead added'); _load(); }
  }
}

// ===========================================================================
// Deals tab — grouped by stage (kanban-style columns scroll horizontally)
// ===========================================================================

class _DealsTab extends StatefulWidget {
  const _DealsTab({required this.auth});
  final AuthService auth;
  @override
  State<_DealsTab> createState() => _DealsTabState();
}

class _DealsTabState extends State<_DealsTab> {
  bool _loading = true;
  List<dynamic> _deals = [];
  List<String> _stages = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/crm/deals'));
      _deals = (d['deals'] as List?) ?? [];
      _stages = ((d['stages'] as List?) ?? []).map((e) => e.toString()).toList();
      if (_stages.isEmpty) _stages = ['Qualification', 'Proposal', 'Negotiation', 'Closing'];
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  int get _openValue => _deals.where((d) => d['status'] == 'open').fold(0, (a, d) => a + ((d['value_paise'] as num?)?.toInt() ?? 0));

  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    final wonCount = _deals.where((d) => d['status'] == 'won').length;
    return Stack(children: [
      RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.fromLTRB(hp, 8, hp, 100),
          children: [
            Text('${_deals.length} deals · ${_money(_openValue)} open · $wonCount won', style: AppleTheme.subhead(context)),
            const SizedBox(height: 14),
            for (final stage in _stages) ..._stageSection(stage),
            // Deals in a stage not in the pipeline list (e.g. legacy).
            ..._orphanStages(),
          ],
        ),
      ),
      _fab(_addDeal),
    ]);
  }

  List<Widget> _orphanStages() {
    final known = _stages.toSet();
    final others = _deals.map((d) => d['stage']?.toString() ?? '').where((s) => s.isNotEmpty && !known.contains(s)).toSet();
    return [for (final s in others) ..._stageSection(s)];
  }

  List<Widget> _stageSection(String stage) {
    final inStage = _deals.where((d) => (d['stage']?.toString() ?? '') == stage).toList();
    final value = inStage.fold(0, (a, d) => a + ((d['value_paise'] as num?)?.toInt() ?? 0));
    return [
      Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 6),
        child: Row(children: [
          Text(stage, style: AppleTheme.headline(context)),
          const SizedBox(width: 8),
          Text('${inStage.length} · ${_money(value)}', style: AppleTheme.footnote(context)),
        ]),
      ),
      if (inStage.isEmpty)
        Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('—', style: AppleTheme.footnote(context)))
      else
        ...inStage.map((d) => _dealCard(d as Map<String, dynamic>)),
    ];
  }

  Widget _dealCard(Map<String, dynamic> d) {
    final status = d['status']?.toString() ?? 'open';
    final sub = [d['account'], d['lead']].where((x) => (x?.toString() ?? '').isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: () => _editDeal(d),
        behavior: HitTestBehavior.opaque,
        child: AppleCard(
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(d['title']?.toString() ?? 'Deal', style: AppleTheme.headline(context)),
              if (sub.isNotEmpty) Text(sub, style: AppleTheme.footnote(context)),
            ])),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(_money((d['value_paise'] as num?) ?? 0, d['currency']?.toString() ?? 'INR'), style: AppleTheme.headline(context)),
              if (status != 'open') Text(status.toUpperCase(), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _statusColor(status))),
            ]),
          ]),
        ),
      ),
    );
  }

  Future<void> _addDeal() async {
    final title = TextEditingController();
    final value = TextEditingController();
    int stage = 0;
    final ok = await showFormSheet(context, title: 'Add Deal', builder: (setS) => [
      sheetField(title, 'Title', CupertinoIcons.briefcase),
      const SizedBox(height: 10),
      sheetField(value, 'Value (₹)', CupertinoIcons.money_dollar, keyboard: TextInputType.number),
      const SizedBox(height: 10),
      AppleSegmented(labels: _stages, selected: stage.clamp(0, _stages.length - 1), onChanged: (i) => setS(() => stage = i)),
    ], onSubmit: () async {
      if (title.text.trim().isEmpty) return 'Title required';
      final rupees = double.tryParse(value.text.trim()) ?? 0;
      try {
        await widget.auth.apiPost('/api/v1/manage/crm/deals', {
          'title': title.text.trim(),
          'value_paise': (rupees * 100).round(),
          'stage': _stages[stage.clamp(0, _stages.length - 1)],
        });
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) { _toast('Deal added'); _load(); }
  }

  Future<void> _editDeal(Map<String, dynamic> d) async {
    final id = d['id'].toString();
    final title = TextEditingController(text: d['title']?.toString() ?? '');
    final value = TextEditingController(text: (((d['value_paise'] as num?) ?? 0) / 100).toStringAsFixed(0));
    int stage = _stages.indexOf(d['stage']?.toString() ?? '');
    if (stage < 0) stage = 0;
    int status = ['open', 'won', 'lost'].indexOf(d['status']?.toString() ?? 'open');
    if (status < 0) status = 0;
    final ok = await showFormSheet(context, title: 'Edit Deal', builder: (setS) => [
      sheetField(title, 'Title', CupertinoIcons.briefcase),
      const SizedBox(height: 10),
      sheetField(value, 'Value (₹)', CupertinoIcons.money_dollar, keyboard: TextInputType.number),
      const SizedBox(height: 10),
      AppleSegmented(labels: _stages, selected: stage.clamp(0, _stages.length - 1), onChanged: (i) => setS(() => stage = i)),
      const SizedBox(height: 10),
      AppleSegmented(labels: const ['Open', 'Won', 'Lost'], selected: status, onChanged: (i) => setS(() => status = i)),
      const SizedBox(height: 14),
      GestureDetector(
        onTap: () async {
          await widget.auth.apiDelete('/api/v1/manage/crm/deals/$id');
          if (context.mounted) Navigator.pop(context, true);
        },
        child: Text('Delete deal', style: TextStyle(color: AppleColors.red, fontWeight: FontWeight.w600)),
      ),
    ], onSubmit: () async {
      if (title.text.trim().isEmpty) return 'Title required';
      final rupees = double.tryParse(value.text.trim()) ?? 0;
      try {
        await widget.auth.apiPatch('/api/v1/manage/crm/deals/$id', {
          'title': title.text.trim(),
          'value_paise': (rupees * 100).round(),
          'stage': _stages[stage.clamp(0, _stages.length - 1)],
          'status': ['open', 'won', 'lost'][status],
        });
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) { _toast('Saved'); _load(); }
  }
}

// ===========================================================================
// Accounts tab
// ===========================================================================

class _AccountsTab extends StatefulWidget {
  const _AccountsTab({required this.auth});
  final AuthService auth;
  @override
  State<_AccountsTab> createState() => _AccountsTabState();
}

class _AccountsTabState extends State<_AccountsTab> {
  bool _loading = true;
  List<dynamic> _accounts = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/crm/accounts'));
      _accounts = (d['accounts'] as List?) ?? [];
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  Color _healthColor(String h) => switch (h) {
        'healthy' => AppleColors.green,
        'at_risk' => AppleColors.orange,
        'churn_risk' => AppleColors.red,
        _ => const Color(0xFF8E8E93),
      };

  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    return Stack(children: [
      RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.fromLTRB(hp, 8, hp, 100),
          children: [
            Text('${_accounts.length} accounts', style: AppleTheme.subhead(context)),
            const SizedBox(height: 14),
            if (_accounts.isEmpty)
              AppleCard(child: Text('No accounts yet. Add a company with the button below.', style: AppleTheme.footnote(context)))
            else
              ..._accounts.map((a) => _accountCard(a as Map<String, dynamic>)),
          ],
        ),
      ),
      _fab(_addAccount),
    ]);
  }

  Widget _accountCard(Map<String, dynamic> a) {
    final health = a['health']?.toString() ?? 'unknown';
    final hc = _healthColor(health);
    final sub = [a['industry'], a['size_band'], if (((a['deal_count'] as num?) ?? 0) > 0) '${a['deal_count']} deals'].where((x) => (x?.toString() ?? '').isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: () => _editAccount(a),
        behavior: HitTestBehavior.opaque,
        child: AppleCard(
          child: Row(children: [
            Container(width: 40, height: 40, alignment: Alignment.center, decoration: BoxDecoration(color: hc.withOpacity(0.14), borderRadius: BorderRadius.zero), child: Icon(CupertinoIcons.building_2_fill, color: hc, size: 20)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a['name']?.toString() ?? 'Account', style: AppleTheme.headline(context)),
              if (sub.isNotEmpty) Text(sub, style: AppleTheme.footnote(context)),
            ])),
            if (((a['arr_paise'] as num?) ?? 0) > 0) Text('${_money((a['arr_paise'] as num?) ?? 0)}/yr', style: AppleTheme.footnote(context)),
          ]),
        ),
      ),
    );
  }

  Future<void> _addAccount() => _accountForm(null);
  Future<void> _editAccount(Map<String, dynamic> a) => _accountForm(a);

  Future<void> _accountForm(Map<String, dynamic>? a) async {
    final editing = a != null;
    final name = TextEditingController(text: a?['name']?.toString() ?? '');
    final domain = TextEditingController(text: a?['domain']?.toString() ?? '');
    final industry = TextEditingController(text: a?['industry']?.toString() ?? '');
    final arr = TextEditingController(text: editing ? (((a['arr_paise'] as num?) ?? 0) / 100).toStringAsFixed(0) : '');
    const healths = ['unknown', 'healthy', 'at_risk', 'churn_risk'];
    int health = healths.indexOf(a?['health']?.toString() ?? 'unknown');
    if (health < 0) health = 0;
    final ok = await showFormSheet(context, title: editing ? 'Edit Account' : 'Add Account', builder: (setS) => [
      sheetField(name, 'Company name', CupertinoIcons.building_2_fill),
      const SizedBox(height: 10),
      sheetField(domain, 'Domain (e.g. acme.com)', CupertinoIcons.globe),
      const SizedBox(height: 10),
      sheetField(industry, 'Industry', CupertinoIcons.briefcase),
      const SizedBox(height: 10),
      sheetField(arr, 'Annual value (₹)', CupertinoIcons.money_dollar, keyboard: TextInputType.number),
      const SizedBox(height: 10),
      AppleSegmented(labels: const ['Unknown', 'Healthy', 'At risk', 'Churn'], selected: health, onChanged: (i) => setS(() => health = i)),
      if (editing) ...[
        const SizedBox(height: 14),
        GestureDetector(
          onTap: () async {
            await widget.auth.apiDelete('/api/v1/manage/crm/accounts/${a['id']}');
            if (context.mounted) Navigator.pop(context, true);
          },
          child: Text('Delete account', style: TextStyle(color: AppleColors.red, fontWeight: FontWeight.w600)),
        ),
      ],
    ], onSubmit: () async {
      if (name.text.trim().isEmpty) return 'Name required';
      final payload = {
        'name': name.text.trim(),
        'domain': domain.text.trim(),
        'industry': industry.text.trim(),
        'arr_paise': ((double.tryParse(arr.text.trim()) ?? 0) * 100).round(),
        'health': healths[health],
      };
      try {
        if (editing) {
          await widget.auth.apiPatch('/api/v1/manage/crm/accounts/${a['id']}', payload);
        } else {
          await widget.auth.apiPost('/api/v1/manage/crm/accounts', payload);
        }
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) { _toast('Saved'); _load(); }
  }
}

// ===========================================================================
// Broadcasts / Campaigns tab
// ===========================================================================

class _BroadcastsTab extends StatefulWidget {
  const _BroadcastsTab({required this.auth});
  final AuthService auth;
  @override
  State<_BroadcastsTab> createState() => _BroadcastsTabState();
}

class _BroadcastsTabState extends State<_BroadcastsTab> {
  bool _loading = true;
  List<dynamic> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/crm/broadcasts'));
      _items = (d['broadcasts'] as List?) ?? [];
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    return Stack(children: [
      RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.fromLTRB(hp, 8, hp, 100),
          children: [
            Text('${_items.length} campaigns', style: AppleTheme.subhead(context)),
            const SizedBox(height: 14),
            if (_items.isEmpty)
              AppleCard(child: Text('No campaigns yet. Compose an email or WhatsApp broadcast below.', style: AppleTheme.footnote(context)))
            else
              ..._items.map((b) => _card(b as Map<String, dynamic>)),
          ],
        ),
      ),
      _fab(_compose),
    ]);
  }

  Widget _card(Map<String, dynamic> b) {
    final channel = b['channel']?.toString() ?? 'email';
    final status = b['status']?.toString() ?? 'draft';
    final sent = status == 'sent';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppleCard(
        child: Row(children: [
          Container(width: 40, height: 40, alignment: Alignment.center,
              decoration: BoxDecoration(color: (channel == 'email' ? AppleColors.blue : AppleColors.green).withOpacity(0.14), borderRadius: BorderRadius.zero),
              child: Icon(channel == 'email' ? CupertinoIcons.mail_solid : CupertinoIcons.chat_bubble_fill, color: channel == 'email' ? AppleColors.blue : AppleColors.green, size: 20)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(b['name']?.toString() ?? 'Campaign', style: AppleTheme.headline(context)),
            Text(sent ? 'Sent to ${b['total_sent']} · ${channel == 'email' ? 'Email' : 'WhatsApp'}' : '${status[0].toUpperCase()}${status.substring(1)} · ${channel == 'email' ? 'Email' : 'WhatsApp'}',
                style: AppleTheme.footnote(context)),
          ])),
          if (!sent)
            GestureDetector(
              onTap: () => _send(b),
              child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(color: Palette.of(context).accent, borderRadius: BorderRadius.zero),
                  child: const Text('Send', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600))),
            )
          else
            const Icon(CupertinoIcons.checkmark_circle_fill, color: AppleColors.green, size: 20),
        ]),
      ),
    );
  }

  Future<void> _send(Map<String, dynamic> b) async {
    try {
      final r = ApiClient.decode(await widget.auth.apiPost('/api/v1/manage/crm/broadcasts/${b['id']}/send', {}));
      _toast('Sent to ${r['total_targets'] ?? 0} contacts');
      _load();
    } catch (_) {
      _toast('Could not send');
    }
  }

  Future<void> _compose() async {
    final name = TextEditingController();
    final subject = TextEditingController();
    final body = TextEditingController();
    int channel = 0; // email, whatsapp
    final ok = await showFormSheet(context, title: 'New Campaign', builder: (setS) => [
      AppleSegmented(labels: const ['Email', 'WhatsApp'], selected: channel, onChanged: (i) => setS(() => channel = i)),
      const SizedBox(height: 10),
      sheetField(name, 'Campaign name', CupertinoIcons.tag),
      if (channel == 0) ...[
        const SizedBox(height: 10),
        sheetField(subject, 'Subject', CupertinoIcons.textformat),
      ],
      const SizedBox(height: 10),
      sheetField(body, 'Message', CupertinoIcons.text_alignleft),
    ], onSubmit: () async {
      if (name.text.trim().isEmpty) return 'Name required';
      if (body.text.trim().isEmpty) return 'Message required';
      try {
        await widget.auth.apiPost('/api/v1/manage/crm/broadcasts', {
          'name': name.text.trim(),
          'channel': channel == 0 ? 'email' : 'whatsapp',
          'subject': subject.text.trim(),
          'body': body.text.trim(),
        });
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) { _toast('Campaign created'); _load(); }
  }
}

// ===========================================================================
// Invoices tab
// ===========================================================================

Color _invoiceColor(String s) => switch (s) {
      'paid' => AppleColors.green,
      'sent' => AppleColors.blue,
      'cancelled' => AppleColors.red,
      _ => const Color(0xFF8E8E93),
    };

class _InvoicesTab extends StatefulWidget {
  const _InvoicesTab({required this.auth});
  final AuthService auth;
  @override
  State<_InvoicesTab> createState() => _InvoicesTabState();
}

class _InvoicesTabState extends State<_InvoicesTab> {
  bool _loading = true;
  List<dynamic> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _items = (ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/crm/invoices'))['invoices'] as List?) ?? [];
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  int get _outstanding => _items.where((i) => i['status'] != 'paid' && i['status'] != 'cancelled').fold(0, (a, i) => a + ((i['total'] as num?)?.toInt() ?? 0));

  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    return Stack(children: [
      RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.fromLTRB(hp, 8, hp, 100),
          children: [
            Text('${_items.length} invoices · ${_money(_outstanding)} outstanding', style: AppleTheme.subhead(context)),
            const SizedBox(height: 14),
            if (_items.isEmpty)
              AppleCard(child: Text('No invoices yet. Create one with the button below.', style: AppleTheme.footnote(context)))
            else
              ..._items.map((i) => _card(i as Map<String, dynamic>)),
          ],
        ),
      ),
      _fab(_create),
    ]);
  }

  Widget _card(Map<String, dynamic> inv) {
    final status = inv['status']?.toString() ?? 'draft';
    final c = _invoiceColor(status);
    final who = [inv['lead'], inv['account']].where((x) => (x?.toString() ?? '').isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: () => _open(inv),
        behavior: HitTestBehavior.opaque,
        child: AppleCard(
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Invoice #${inv['number']}', style: AppleTheme.headline(context)),
              if (who.isNotEmpty) Text(who, style: AppleTheme.footnote(context)),
            ])),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(_money((inv['total'] as num?) ?? 0, inv['currency']?.toString() ?? 'INR'), style: AppleTheme.headline(context)),
              Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: c.withOpacity(0.14), borderRadius: BorderRadius.zero),
                  child: Text(status, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c))),
            ]),
          ]),
        ),
      ),
    );
  }

  Future<void> _create() async {
    final amount = TextEditingController();
    final notes = TextEditingController();
    final ok = await showFormSheet(context, title: 'New Invoice', builder: (setS) => [
      sheetField(amount, 'Amount (₹)', CupertinoIcons.money_dollar, keyboard: TextInputType.number),
      const SizedBox(height: 10),
      sheetField(notes, 'Notes (optional)', CupertinoIcons.text_alignleft),
    ], onSubmit: () async {
      final rupees = double.tryParse(amount.text.trim()) ?? 0;
      if (rupees <= 0) return 'Enter an amount';
      try {
        await widget.auth.apiPost('/api/v1/manage/crm/invoices', {'total': (rupees * 100).round(), 'notes': notes.text.trim()});
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) { _toast('Invoice created'); _load(); }
  }

  Future<void> _open(Map<String, dynamic> inv) async {
    final id = inv['id'].toString();
    final changed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        final p = Palette.of(ctx);
        return Container(
          margin: const EdgeInsets.all(10),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.zero),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Invoice #${inv['number']}', style: AppleTheme.title2(ctx)),
            Text('${_money((inv['total'] as num?) ?? 0)} · ${inv['status']}', style: AppleTheme.subhead(ctx)),
            const SizedBox(height: 16),
            for (final s in const ['sent', 'paid', 'cancelled'])
              ListTile(
                leading: Icon(CupertinoIcons.circle, color: _invoiceColor(s)),
                title: Text('Mark $s', style: AppleTheme.body(ctx)),
                onTap: () async {
                  await widget.auth.apiPost('/api/v1/manage/crm/invoices/$id/status', {'status': s});
                  if (ctx.mounted) Navigator.pop(ctx, true);
                },
              ),
            ListTile(
              leading: const Icon(CupertinoIcons.money_dollar_circle, color: AppleColors.green),
              title: Text('Record payment', style: AppleTheme.body(ctx)),
              onTap: () async { Navigator.pop(ctx, false); await _recordPayment(id); _load(); },
            ),
            ListTile(
              leading: const Icon(CupertinoIcons.link, color: AppleColors.blue),
              title: Text('Payment link', style: AppleTheme.body(ctx)),
              onTap: () async { Navigator.pop(ctx, false); await _paymentLink(id); },
            ),
            ListTile(
              leading: const Icon(CupertinoIcons.trash, color: AppleColors.red),
              title: Text('Delete invoice', style: AppleTheme.body(ctx)),
              onTap: () async {
                await widget.auth.apiDelete('/api/v1/manage/crm/invoices/$id');
                if (ctx.mounted) Navigator.pop(ctx, true);
              },
            ),
          ]),
        );
      },
    );
    if (changed == true) { _toast('Updated'); _load(); }
  }

  Future<void> _recordPayment(String invoiceId) async {
    final amount = TextEditingController();
    await showFormSheet(context, title: 'Record Payment', builder: (setS) => [
      sheetField(amount, 'Amount received (₹)', CupertinoIcons.money_dollar, keyboard: TextInputType.number),
    ], onSubmit: () async {
      final rupees = double.tryParse(amount.text.trim()) ?? 0;
      if (rupees <= 0) return 'Enter an amount';
      try {
        await widget.auth.apiPost('/api/v1/manage/crm/invoices/$invoiceId/payments', {'amount': (rupees * 100).round(), 'provider': 'manual'});
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
  }

  // Generate a payment link (Razorpay when configured, else a demo link).
  Future<void> _paymentLink(String invoiceId) async {
    try {
      final r = ApiClient.decode(await widget.auth.apiPost('/api/v1/manage/crm/invoices/$invoiceId/payment-link', {}));
      final link = r['link']?.toString() ?? '';
      final demo = r['mode'] != 'live';
      if (!mounted) return;
      await showDialog(context: context, builder: (ctx) => AlertDialog(
        title: Text(demo ? 'Payment link (demo)' : 'Payment link'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          SelectableText(link.isEmpty ? '(Razorpay configured — wire the live call)' : link),
          if (demo) const Padding(padding: EdgeInsets.only(top: 10), child: Text('Set RAZORPAY_KEY_ID + RAZORPAY_KEY_SECRET to generate real links.', style: TextStyle(fontSize: 12))),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ));
    } catch (_) {
      if (mounted) _toast('Could not create link');
    }
  }
}

// ===========================================================================
// Forms tab
// ===========================================================================

class _FormsTab extends StatefulWidget {
  const _FormsTab({required this.auth});
  final AuthService auth;
  @override
  State<_FormsTab> createState() => _FormsTabState();
}

class _FormsTabState extends State<_FormsTab> {
  bool _loading = true;
  List<dynamic> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _items = (ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/crm/forms'))['forms'] as List?) ?? [];
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    return Stack(children: [
      RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.fromLTRB(hp, 8, hp, 100),
          children: [
            Text('${_items.length} forms', style: AppleTheme.subhead(context)),
            const SizedBox(height: 14),
            if (_items.isEmpty)
              AppleCard(child: Text('No forms yet. Create a lead-capture form below.', style: AppleTheme.footnote(context)))
            else
              ..._items.map((f) => _card(f as Map<String, dynamic>)),
          ],
        ),
      ),
      _fab(_create),
    ]);
  }

  Widget _card(Map<String, dynamic> f) {
    final subs = ((f['submissions'] as num?) ?? 0).toInt();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: () => _open(f),
        behavior: HitTestBehavior.opaque,
        child: AppleCard(
          child: Row(children: [
            Container(width: 40, height: 40, alignment: Alignment.center, decoration: BoxDecoration(color: AppleColors.blue.withOpacity(0.14), borderRadius: BorderRadius.zero), child: const Icon(CupertinoIcons.doc_text_fill, color: AppleColors.blue, size: 20)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(f['name']?.toString() ?? 'Form', style: AppleTheme.headline(context)),
              Text('/f/${f['slug']} · $subs submissions', style: AppleTheme.footnote(context)),
            ])),
            if (f['enabled'] != true) Text('Off', style: TextStyle(color: AppleColors.red, fontSize: 12, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }

  Future<void> _create() async {
    final name = TextEditingController();
    final fields = TextEditingController(text: 'Name, Email, Phone');
    final ok = await showFormSheet(context, title: 'New Form', builder: (setS) => [
      sheetField(name, 'Form name', CupertinoIcons.doc_text),
      const SizedBox(height: 10),
      sheetField(fields, 'Fields (comma separated)', CupertinoIcons.list_bullet),
    ], onSubmit: () async {
      if (name.text.trim().isEmpty) return 'Name required';
      final fieldList = fields.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      try {
        await widget.auth.apiPost('/api/v1/manage/crm/forms', {'name': name.text.trim(), 'fields': fieldList});
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) { _toast('Form created'); _load(); }
  }

  Future<void> _open(Map<String, dynamic> f) async {
    final id = f['id'].toString();
    List<dynamic> subs = [];
    try {
      subs = (ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/crm/forms/$id/submissions'))['submissions'] as List?) ?? [];
    } catch (_) {}
    if (!mounted) return;
    final deleted = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        final p = Palette.of(ctx);
        return Container(
          margin: const EdgeInsets.all(10),
          padding: const EdgeInsets.all(20),
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.zero),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(f['name']?.toString() ?? 'Form', style: AppleTheme.title2(ctx)),
            Text('Public URL: /f/${f['slug']}', style: AppleTheme.footnote(ctx)),
            const SizedBox(height: 12),
            Text('Submissions (${subs.length})', style: AppleTheme.headline(ctx)),
            const SizedBox(height: 6),
            Flexible(
              child: subs.isEmpty
                  ? Text('No submissions yet.', style: AppleTheme.footnote(ctx))
                  : ListView(shrinkWrap: true, children: subs.map((s) {
                      final data = (s as Map)['data'];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(data.toString(), style: AppleTheme.footnote(ctx)),
                      );
                    }).toList()),
            ),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () async {
                await widget.auth.apiDelete('/api/v1/manage/crm/forms/$id');
                if (ctx.mounted) Navigator.pop(ctx, true);
              },
              child: Text('Delete form', style: TextStyle(color: AppleColors.red, fontWeight: FontWeight.w600)),
            ),
          ]),
        );
      },
    );
    if (deleted == true) { _toast('Deleted'); _load(); }
  }
}

// Shared floating "+" button, bottom-right of a tab.
Widget _fab(VoidCallback onTap) => Positioned(
      right: 20, bottom: 24,
      child: Builder(builder: (context) => FloatingActionButton(
            onPressed: onTap,
            backgroundColor: Palette.of(context).accent,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            child: const Icon(CupertinoIcons.add, color: Colors.white),
          )),
    );

// ===========================================================================
// Lead detail
// ===========================================================================

class LeadDetailScreen extends StatefulWidget {
  const LeadDetailScreen({super.key, required this.auth, required this.lead});
  final AuthService auth;
  final Map<String, dynamic> lead;

  @override
  State<LeadDetailScreen> createState() => _LeadDetailScreenState();
}

class _LeadDetailScreenState extends State<LeadDetailScreen> {
  late Map<String, dynamic> _lead;
  List<dynamic> _activities = [];
  List<dynamic> _tasks = [];
  bool _loading = true;

  String get _id => _lead['id'].toString();

  @override
  void initState() {
    super.initState();
    _lead = Map<String, dynamic>.from(widget.lead);
    _load();
  }

  Future<void> _load() async {
    try {
      _activities = (ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/crm/leads/$_id/activities'))['activities'] as List?) ?? [];
      _tasks = (ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/crm/leads/$_id/tasks'))['tasks'] as List?) ?? [];
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  Future<void> _changeStatus() async {
    final current = _lead['status']?.toString() ?? 'New Lead';
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
            Text('Move to…', style: AppleTheme.headline(ctx)),
            const SizedBox(height: 8),
            ..._leadStatuses.map((s) => ListTile(
                  leading: Icon(s == current ? CupertinoIcons.largecircle_fill_circle : CupertinoIcons.circle, color: _statusColor(s)),
                  title: Text(s, style: AppleTheme.body(ctx)),
                  onTap: () => Navigator.pop(ctx, s),
                )),
            const SizedBox(height: 8),
          ]),
        );
      },
    );
    if (picked == null || picked == current) return;
    try {
      await widget.auth.apiPost('/api/v1/manage/crm/leads/$_id/status', {'status': picked});
      setState(() => _lead['status'] = picked);
      _toast('Moved to $picked');
    } catch (_) {
      _toast('Could not update status');
    }
  }

  Future<void> _editLead() async {
    final name = TextEditingController(text: _lead['name']?.toString() ?? '');
    final phone = TextEditingController(text: _lead['phone']?.toString() ?? '');
    final email = TextEditingController(text: _lead['email']?.toString() ?? '');
    final counsellor = TextEditingController(text: _lead['assigned_counsellor']?.toString() ?? '');
    final notes = TextEditingController(text: _lead['notes']?.toString() ?? '');
    final ok = await showFormSheet(context, title: 'Edit Lead', builder: (setS) => [
      sheetField(name, 'Full name', CupertinoIcons.person),
      const SizedBox(height: 10),
      sheetField(phone, 'Phone', CupertinoIcons.phone, keyboard: TextInputType.phone),
      const SizedBox(height: 10),
      sheetField(email, 'Email', CupertinoIcons.mail, keyboard: TextInputType.emailAddress),
      const SizedBox(height: 10),
      sheetField(counsellor, 'Assigned counsellor', CupertinoIcons.person_badge_plus),
      const SizedBox(height: 10),
      sheetField(notes, 'Notes', CupertinoIcons.text_alignleft),
    ], onSubmit: () async {
      if (name.text.trim().isEmpty) return 'Name required';
      try {
        await widget.auth.apiPatch('/api/v1/manage/crm/leads/$_id', {
          'name': name.text.trim(), 'phone': phone.text.trim(), 'email': email.text.trim(),
          'assigned_counsellor': counsellor.text.trim(), 'notes': notes.text.trim(),
        });
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) {
      setState(() {
        _lead['name'] = name.text.trim();
        _lead['phone'] = phone.text.trim();
        _lead['email'] = email.text.trim();
        _lead['assigned_counsellor'] = counsellor.text.trim();
        _lead['notes'] = notes.text.trim();
      });
      _toast('Saved');
    }
  }

  Future<void> _addActivity() async {
    final subject = TextEditingController();
    final message = TextEditingController();
    int type = 0;
    const types = ['note', 'call', 'email', 'whatsapp'];
    final ok = await showFormSheet(context, title: 'Log Activity', builder: (setS) => [
      AppleSegmented(labels: const ['Note', 'Call', 'Email', 'WhatsApp'], selected: type, onChanged: (i) => setS(() => type = i)),
      const SizedBox(height: 10),
      sheetField(subject, 'Subject (optional)', CupertinoIcons.textformat),
      const SizedBox(height: 10),
      sheetField(message, 'Details', CupertinoIcons.text_alignleft),
    ], onSubmit: () async {
      if (message.text.trim().isEmpty && subject.text.trim().isEmpty) return 'Enter a subject or details';
      try {
        await widget.auth.apiPost('/api/v1/manage/crm/leads/$_id/activities', {'type': types[type], 'subject': subject.text.trim(), 'message': message.text.trim()});
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) { _toast('Logged'); _load(); }
  }

  // Send a message to the lead via WhatsApp / SMS / Email. Uses the configured
  // provider if available, else runs in demo mode (still logged to the timeline).
  Future<void> _sendMessage() async {
    final message = TextEditingController();
    int channel = 0;
    const channels = ['whatsapp', 'sms', 'email'];
    final ok = await showFormSheet(context, title: 'Send Message', builder: (setS) => [
      AppleSegmented(labels: const ['WhatsApp', 'SMS', 'Email'], selected: channel, onChanged: (i) => setS(() => channel = i)),
      const SizedBox(height: 10),
      sheetField(message, 'Message', CupertinoIcons.text_alignleft),
    ], onSubmit: () async {
      if (message.text.trim().isEmpty) return 'Enter a message';
      try {
        final r = ApiClient.decode(await widget.auth.apiPost('/api/v1/manage/crm/leads/$_id/message', {'channel': channels[channel], 'message': message.text.trim()}));
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r['mode'] == 'live' ? 'Sent via ${channels[channel]}' : 'Sent (demo — set the ${channels[channel]} API key to go live)'), behavior: SnackBarBehavior.floating));
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) _load();
  }

  Future<void> _addTask() async {
    final title = TextEditingController();
    DateTime due = DateTime.now().add(const Duration(days: 1));
    bool high = false;
    final ok = await showFormSheet(context, title: 'Add Task', builder: (setS) => [
      sheetField(title, 'Task (e.g. Call back)', CupertinoIcons.checkmark_square),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: Text('Due: ${_fmtDate(due)}', style: AppleTheme.footnote(context))),
        CupertinoButton(padding: EdgeInsets.zero, child: const Text('Pick'), onPressed: () async {
          final d = await showDatePicker(context: context, initialDate: due, firstDate: DateTime.now().subtract(const Duration(days: 1)), lastDate: DateTime.now().add(const Duration(days: 365)));
          if (d != null) setS(() => due = d);
        }),
      ]),
      Row(children: [Text('High priority', style: AppleTheme.footnote(context)), const Spacer(), CupertinoSwitch(value: high, onChanged: (v) => setS(() => high = v))]),
    ], onSubmit: () async {
      if (title.text.trim().isEmpty) return 'Title required';
      try {
        await widget.auth.apiPost('/api/v1/manage/crm/leads/$_id/tasks', {'title': title.text.trim(), 'due_at': due.toUtc().toIso8601String(), 'priority': high ? 'high' : 'normal'});
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) { _toast('Task added'); _load(); }
  }

  Future<void> _toggleTask(Map<String, dynamic> t) async {
    final next = t['status'] == 'completed' ? 'open' : 'completed';
    try {
      await widget.auth.apiPost('/api/v1/manage/crm/tasks/${t['id']}/status', {'status': next});
      _load();
    } catch (_) {
      _toast('Could not update task');
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _lead['status']?.toString() ?? 'New Lead';
    final sc = _statusColor(status);
    return Scaffold(
      backgroundColor: Palette.of(context).bg,
      appBar: AppBar(title: Text(_lead['name']?.toString() ?? 'Lead'), actions: [IconButton(icon: const Icon(CupertinoIcons.pencil), onPressed: _editLead)]),
      body: _loading
          ? const Center(child: CupertinoActivityIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 40),
              children: [
                AppleCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(_lead['name']?.toString() ?? 'Lead', style: AppleTheme.title2(context))),
                      GestureDetector(
                        onTap: _changeStatus,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(color: sc.withOpacity(0.14), borderRadius: BorderRadius.zero),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Text(status, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: sc)),
                            const SizedBox(width: 4),
                            Icon(CupertinoIcons.chevron_down, size: 12, color: sc),
                          ]),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    if ((_lead['phone']?.toString() ?? '').isNotEmpty) _kv(CupertinoIcons.phone, _lead['phone'].toString()),
                    if ((_lead['email']?.toString() ?? '').isNotEmpty) _kv(CupertinoIcons.mail, _lead['email'].toString()),
                    if ((_lead['source']?.toString() ?? '').isNotEmpty) _kv(CupertinoIcons.tag, _lead['source'].toString()),
                    if ((_lead['assigned_counsellor']?.toString() ?? '').isNotEmpty) _kv(CupertinoIcons.person_badge_plus, _lead['assigned_counsellor'].toString()),
                    if ((_lead['notes']?.toString() ?? '').isNotEmpty) ...[const SizedBox(height: 8), Text(_lead['notes'].toString(), style: AppleTheme.footnote(context))],
                  ]),
                ),
                const SizedBox(height: 20),
                Row(children: [Expanded(child: SectionHeader('Tasks (${_tasks.length})')), _smallBtn('Add', _addTask)]),
                if (_tasks.isEmpty) AppleCard(child: Text('No tasks. Schedule a follow-up.', style: AppleTheme.footnote(context))) else ..._tasks.map((t) => _taskRow(t as Map<String, dynamic>)),
                const SizedBox(height: 20),
                Row(children: [Expanded(child: SectionHeader('Activity (${_activities.length})')), _smallBtn('Message', _sendMessage), const SizedBox(width: 6), _smallBtn('Log', _addActivity)]),
                if (_activities.isEmpty) AppleCard(child: Text('No activity yet.', style: AppleTheme.footnote(context))) else ..._activities.map((a) => _activityRow(a as Map<String, dynamic>)),
              ],
            ),
    );
  }

  Widget _kv(IconData icon, String v) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(children: [Icon(icon, size: 15, color: Palette.of(context).secondary), const SizedBox(width: 8), Expanded(child: Text(v, style: AppleTheme.body(context)))]),
      );

  Widget _smallBtn(String label, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: Palette.of(context).accent.withOpacity(0.12), borderRadius: BorderRadius.zero),
          child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(CupertinoIcons.add, size: 14, color: Palette.of(context).accent), const SizedBox(width: 4), Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Palette.of(context).accent))]),
        ),
      );

  Widget _taskRow(Map<String, dynamic> t) {
    final done = t['status'] == 'completed';
    final high = t['priority'] == 'high';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppleCard(
        child: Row(children: [
          GestureDetector(onTap: () => _toggleTask(t), child: Icon(done ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle, color: done ? AppleColors.green : Palette.of(context).secondary)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t['title']?.toString() ?? 'Task', style: AppleTheme.body(context).copyWith(decoration: done ? TextDecoration.lineThrough : null)),
            Text('Due ${_fmtDate(_parse(t['due_at']))}', style: AppleTheme.footnote(context)),
          ])),
          if (high) const Icon(CupertinoIcons.flag_fill, size: 16, color: AppleColors.orange),
        ]),
      ),
    );
  }

  Widget _activityRow(Map<String, dynamic> a) {
    final type = a['type']?.toString() ?? 'note';
    final icon = switch (type) {
      'call' => CupertinoIcons.phone_fill,
      'email' => CupertinoIcons.mail_solid,
      'whatsapp' => CupertinoIcons.chat_bubble_fill,
      _ => CupertinoIcons.text_quote,
    };
    final subject = a['subject']?.toString() ?? '';
    final message = a['message']?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppleCard(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: Palette.of(context).accent),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(subject.isEmpty ? type[0].toUpperCase() + type.substring(1) : subject, style: AppleTheme.headline(context)),
            if (message.isNotEmpty) Text(message, style: AppleTheme.footnote(context)),
            Text([_fmtDate(_parse(a['at'])), if ((a['author']?.toString() ?? '').isNotEmpty) a['author']].join(' · '), style: AppleTheme.footnote(context)),
          ])),
        ]),
      ),
    );
  }

  static DateTime? _parse(dynamic v) => v == null ? null : DateTime.tryParse(v.toString())?.toLocal();
  static String _fmtDate(DateTime? d) {
    if (d == null) return '—';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }
}

// ===========================================================================
// Batch 2 tabs
// ===========================================================================

class _AnalyticsTab extends StatefulWidget {
  const _AnalyticsTab({required this.auth});
  final AuthService auth;
  @override
  State<_AnalyticsTab> createState() => _AnalyticsTabState();
}

class _AnalyticsTabState extends State<_AnalyticsTab> {
  bool _loading = true;
  Map<String, dynamic> _k = {};
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { _k = ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/crm/analytics')); } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }
  num _n(String k) => (_k[k] as num?) ?? 0;
  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    Widget card(String label, String value) => Expanded(child: AppleCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(value, style: AppleTheme.title2(context)),
      Text(label, style: AppleTheme.footnote(context)),
    ])));
    return RefreshIndicator(onRefresh: _load, child: ListView(padding: EdgeInsets.fromLTRB(hp, 8, hp, 40), children: [
      Text('Overview', style: AppleTheme.subhead(context)),
      const SizedBox(height: 12),
      Row(children: [card('Leads', '${_n('leads_total')}'), const SizedBox(width: 12), card('Converted', '${_n('leads_converted')}')]),
      const SizedBox(height: 12),
      Row(children: [card('Open deals', '${_n('deals_open')}'), const SizedBox(width: 12), card('Pipeline', _money(_n('deals_open_value')))]),
      const SizedBox(height: 12),
      Row(children: [card('Won', _money(_n('deals_won_value'))), const SizedBox(width: 12), card('Collected', _money(_n('revenue_collected')))]),
      const SizedBox(height: 12),
      Row(children: [card('Outstanding', _money(_n('invoices_outstanding'))), const SizedBox(width: 12), card('Open tickets', '${_n('open_tickets')}')]),
    ]));
  }
}

class _AutomationTab extends StatefulWidget {
  const _AutomationTab({required this.auth});
  final AuthService auth;
  @override
  State<_AutomationTab> createState() => _AutomationTabState();
}

class _AutomationTabState extends State<_AutomationTab> {
  bool _loading = true;
  List<dynamic> _rules = [];
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { _rules = (ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/crm/automation'))['rules'] as List?) ?? []; } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }
  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    return Stack(children: [
      RefreshIndicator(onRefresh: _load, child: ListView(padding: EdgeInsets.fromLTRB(hp, 8, hp, 100), children: [
        Text('${_rules.length} rules', style: AppleTheme.subhead(context)),
        const SizedBox(height: 12),
        if (_rules.isEmpty) AppleCard(child: Text('No automation rules. Create one to auto-act when a lead changes stage.', style: AppleTheme.footnote(context)))
        else ..._rules.map((r) => _row(r as Map<String, dynamic>)),
      ])),
      _fab(_create),
    ]);
  }
  Widget _row(Map<String, dynamic> r) {
    final enabled = r['enabled'] == true;
    final act = r['action'] == 'log_note' ? 'log note' : 'create task';
    return Padding(padding: const EdgeInsets.only(bottom: 12), child: AppleCard(child: Row(children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(r['name']?.toString() ?? 'Rule', style: AppleTheme.headline(context)),
        Text('When → ${r['trigger_status']}, after ${r['delay_hours']}h $act', style: AppleTheme.footnote(context)),
      ])),
      CupertinoSwitch(value: enabled, onChanged: (_) async { await widget.auth.apiPost('/api/v1/manage/crm/automation/${r['id']}/toggle', {}); _load(); }),
      GestureDetector(onTap: () async { await widget.auth.apiDelete('/api/v1/manage/crm/automation/${r['id']}'); _load(); }, child: const Icon(CupertinoIcons.trash, size: 18, color: AppleColors.red)),
    ])));
  }
  Future<void> _create() async {
    final name = TextEditingController();
    final value = TextEditingController();
    final delay = TextEditingController(text: '24');
    int trig = 0;
    int action = 0;
    final ok = await showFormSheet(context, title: 'New Rule', builder: (setS) => [
      sheetField(name, 'Rule name', CupertinoIcons.bolt),
      const SizedBox(height: 10),
      Text('When lead enters status', style: AppleTheme.footnote(context)),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, children: [for (var i = 0; i < _leadStatuses.length; i++) GestureDetector(
        onTap: () => setS(() => trig = i),
        child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: trig == i ? Palette.of(context).accent : Palette.of(context).card2, borderRadius: BorderRadius.zero),
          child: Text(_leadStatuses[i], style: TextStyle(fontSize: 12, color: trig == i ? Colors.white : Palette.of(context).label))))]),
      const SizedBox(height: 10),
      AppleSegmented(labels: const ['Create task', 'Log note'], selected: action, onChanged: (i) => setS(() => action = i)),
      const SizedBox(height: 10),
      sheetField(value, action == 0 ? 'Task title' : 'Note text', CupertinoIcons.text_alignleft),
      const SizedBox(height: 10),
      sheetField(delay, 'Delay (hours)', CupertinoIcons.clock, keyboard: TextInputType.number),
    ], onSubmit: () async {
      if (name.text.trim().isEmpty) return 'Name required';
      try {
        await widget.auth.apiPost('/api/v1/manage/crm/automation', {
          'name': name.text.trim(), 'trigger_status': _leadStatuses[trig],
          'action': action == 0 ? 'create_task' : 'log_note', 'action_value': value.text.trim(),
          'delay_hours': int.tryParse(delay.text.trim()) ?? 0,
        });
        return null;
      } on ApiException catch (e) { return e.message; }
    });
    if (ok == true) { _toast('Rule created'); _load(); }
  }
}

class _SurveysTab extends StatefulWidget {
  const _SurveysTab({required this.auth});
  final AuthService auth;
  @override
  State<_SurveysTab> createState() => _SurveysTabState();
}

class _SurveysTabState extends State<_SurveysTab> {
  bool _loading = true;
  List<dynamic> _items = [];
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { _items = (ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/crm/surveys'))['surveys'] as List?) ?? []; } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }
  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    return Stack(children: [
      RefreshIndicator(onRefresh: _load, child: ListView(padding: EdgeInsets.fromLTRB(hp, 8, hp, 100), children: [
        Text('${_items.length} surveys', style: AppleTheme.subhead(context)),
        const SizedBox(height: 12),
        if (_items.isEmpty) AppleCard(child: Text('No surveys yet.', style: AppleTheme.footnote(context)))
        else ..._items.map((s) => Padding(padding: const EdgeInsets.only(bottom: 12), child: AppleCard(child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s['title']?.toString() ?? 'Survey', style: AppleTheme.headline(context)),
            Text('/survey/${s['slug']} · ${s['responses']} responses', style: AppleTheme.footnote(context)),
          ])),
          GestureDetector(onTap: () async { await widget.auth.apiDelete('/api/v1/manage/crm/surveys/${s['id']}'); _load(); }, child: const Icon(CupertinoIcons.trash, size: 18, color: AppleColors.red)),
        ])))),
      ])),
      _fab(_create),
    ]);
  }
  Future<void> _create() async {
    final title = TextEditingController();
    final questions = TextEditingController();
    final ok = await showFormSheet(context, title: 'New Survey', builder: (setS) => [
      sheetField(title, 'Title', CupertinoIcons.doc_text),
      const SizedBox(height: 10),
      sheetField(questions, 'Questions (comma separated)', CupertinoIcons.list_bullet),
    ], onSubmit: () async {
      if (title.text.trim().isEmpty) return 'Title required';
      try {
        await widget.auth.apiPost('/api/v1/manage/crm/surveys', {'title': title.text.trim(), 'questions': questions.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList()});
        return null;
      } on ApiException catch (e) { return e.message; }
    });
    if (ok == true) { _toast('Survey created'); _load(); }
  }
}

class _ReviewsTab extends StatefulWidget {
  const _ReviewsTab({required this.auth});
  final AuthService auth;
  @override
  State<_ReviewsTab> createState() => _ReviewsTabState();
}

class _ReviewsTabState extends State<_ReviewsTab> {
  bool _loading = true;
  List<dynamic> _items = [];
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { _items = (ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/crm/reviews'))['reviews'] as List?) ?? []; } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }
  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    return Stack(children: [
      RefreshIndicator(onRefresh: _load, child: ListView(padding: EdgeInsets.fromLTRB(hp, 8, hp, 100), children: [
        Text('${_items.length} reviews', style: AppleTheme.subhead(context)),
        const SizedBox(height: 12),
        if (_items.isEmpty) AppleCard(child: Text('No reviews yet.', style: AppleTheme.footnote(context)))
        else ..._items.map((r) => _row(r as Map<String, dynamic>)),
      ])),
      _fab(_create),
    ]);
  }
  Widget _row(Map<String, dynamic> r) {
    final status = r['status']?.toString() ?? 'pending';
    final stars = '★' * ((r['rating'] as num?)?.toInt() ?? 0);
    final c = status == 'approved' ? AppleColors.green : (status == 'hidden' ? AppleColors.red : const Color(0xFF8E8E93));
    return Padding(padding: const EdgeInsets.only(bottom: 12), child: AppleCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(r['author']?.toString().isEmpty ?? true ? 'Anonymous' : r['author'].toString(), style: AppleTheme.headline(context))),
        Text(stars, style: const TextStyle(color: AppleColors.orange)),
      ]),
      if ((r['body']?.toString() ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(r['body'].toString(), style: AppleTheme.footnote(context))),
      const SizedBox(height: 8),
      Row(children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: c.withOpacity(0.14), borderRadius: BorderRadius.zero), child: Text(status, style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w700))),
        const Spacer(),
        for (final s in const ['approved', 'hidden']) Padding(padding: const EdgeInsets.only(left: 8), child: GestureDetector(
          onTap: () async { await widget.auth.apiPost('/api/v1/manage/crm/reviews/${r['id']}/status', {'status': s}); _load(); },
          child: Text(s == 'approved' ? 'Approve' : 'Hide', style: TextStyle(fontSize: 12, color: Palette.of(context).accent, fontWeight: FontWeight.w600)))),
      ]),
    ])));
  }
  Future<void> _create() async {
    final author = TextEditingController();
    final body = TextEditingController();
    int rating = 4;
    final ok = await showFormSheet(context, title: 'Add Review', builder: (setS) => [
      sheetField(author, 'Author', CupertinoIcons.person),
      const SizedBox(height: 10),
      AppleSegmented(labels: const ['1★', '2★', '3★', '4★', '5★'], selected: rating, onChanged: (i) => setS(() => rating = i)),
      const SizedBox(height: 10),
      sheetField(body, 'Review', CupertinoIcons.text_alignleft),
    ], onSubmit: () async {
      try {
        await widget.auth.apiPost('/api/v1/manage/crm/reviews', {'author': author.text.trim(), 'rating': rating + 1, 'body': body.text.trim()});
        return null;
      } on ApiException catch (e) { return e.message; }
    });
    if (ok == true) { _toast('Review added'); _load(); }
  }
}

class _CalendarTab extends StatefulWidget {
  const _CalendarTab({required this.auth});
  final AuthService auth;
  @override
  State<_CalendarTab> createState() => _CalendarTabState();
}

class _CalendarTabState extends State<_CalendarTab> {
  bool _loading = true;
  List<dynamic> _items = [];
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { _items = (ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/crm/events'))['events'] as List?) ?? []; } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }
  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    return Stack(children: [
      RefreshIndicator(onRefresh: _load, child: ListView(padding: EdgeInsets.fromLTRB(hp, 8, hp, 100), children: [
        Text('${_items.length} events', style: AppleTheme.subhead(context)),
        const SizedBox(height: 12),
        if (_items.isEmpty) AppleCard(child: Text('No events scheduled.', style: AppleTheme.footnote(context)))
        else ..._items.map((e) => Padding(padding: const EdgeInsets.only(bottom: 12), child: AppleCard(child: Row(children: [
          const Icon(CupertinoIcons.calendar, color: AppleColors.blue),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e['title']?.toString() ?? 'Event', style: AppleTheme.headline(context)),
            Text(_fmtD(e['starts_at']), style: AppleTheme.footnote(context)),
          ])),
          GestureDetector(onTap: () async { await widget.auth.apiDelete('/api/v1/manage/crm/events/${e['id']}'); _load(); }, child: const Icon(CupertinoIcons.trash, size: 18, color: AppleColors.red)),
        ])))),
      ])),
      _fab(_create),
    ]);
  }
  Future<void> _create() async {
    final title = TextEditingController();
    DateTime when = DateTime.now().add(const Duration(days: 1));
    final ok = await showFormSheet(context, title: 'New Event', builder: (setS) => [
      sheetField(title, 'Title', CupertinoIcons.calendar),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: Text('Date: ${_fmtD(when.toIso8601String())}', style: AppleTheme.footnote(context))),
        CupertinoButton(padding: EdgeInsets.zero, child: const Text('Pick'), onPressed: () async {
          final d = await showDatePicker(context: context, initialDate: when, firstDate: DateTime.now().subtract(const Duration(days: 1)), lastDate: DateTime.now().add(const Duration(days: 730)));
          if (d != null) setS(() => when = d);
        }),
      ]),
    ], onSubmit: () async {
      if (title.text.trim().isEmpty) return 'Title required';
      try {
        await widget.auth.apiPost('/api/v1/manage/crm/events', {'title': title.text.trim(), 'starts_at': when.toUtc().toIso8601String()});
        return null;
      } on ApiException catch (e) { return e.message; }
    });
    if (ok == true) { _toast('Event added'); _load(); }
  }
}

class _FeedTab extends StatefulWidget {
  const _FeedTab({required this.auth});
  final AuthService auth;
  @override
  State<_FeedTab> createState() => _FeedTabState();
}

class _FeedTabState extends State<_FeedTab> {
  bool _loading = true;
  List<dynamic> _items = [];
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { _items = (ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/crm/feed'))['posts'] as List?) ?? []; } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }
  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    return Stack(children: [
      RefreshIndicator(onRefresh: _load, child: ListView(padding: EdgeInsets.fromLTRB(hp, 8, hp, 100), children: [
        Text('Team feed', style: AppleTheme.subhead(context)),
        const SizedBox(height: 12),
        if (_items.isEmpty) AppleCard(child: Text('No posts yet.', style: AppleTheme.footnote(context)))
        else ..._items.map((p) => Padding(padding: const EdgeInsets.only(bottom: 12), child: AppleCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(p['body']?.toString() ?? '', style: AppleTheme.body(context)),
          const SizedBox(height: 6),
          Text('${p['author'] ?? ''} · ${_fmtD(p['at'])}', style: AppleTheme.footnote(context)),
        ])))),
      ])),
      _fab(_create),
    ]);
  }
  Future<void> _create() async {
    final body = TextEditingController();
    final ok = await showFormSheet(context, title: 'New Post', builder: (setS) => [
      sheetField(body, 'Share an update…', CupertinoIcons.text_alignleft),
    ], onSubmit: () async {
      if (body.text.trim().isEmpty) return 'Write something';
      try { await widget.auth.apiPost('/api/v1/manage/crm/feed', {'body': body.text.trim()}); return null; }
      on ApiException catch (e) { return e.message; }
    });
    if (ok == true) { _toast('Posted'); _load(); }
  }
}

class _TicketsTab extends StatefulWidget {
  const _TicketsTab({required this.auth});
  final AuthService auth;
  @override
  State<_TicketsTab> createState() => _TicketsTabState();
}

class _TicketsTabState extends State<_TicketsTab> {
  bool _loading = true;
  List<dynamic> _items = [];
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { _items = (ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/crm/tickets'))['tickets'] as List?) ?? []; } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }
  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  Color _tc(String s) => s == 'closed' ? AppleColors.green : (s == 'pending' ? AppleColors.orange : AppleColors.blue);
  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    return Stack(children: [
      RefreshIndicator(onRefresh: _load, child: ListView(padding: EdgeInsets.fromLTRB(hp, 8, hp, 100), children: [
        Text('${_items.where((t) => t['status'] != 'closed').length} open tickets', style: AppleTheme.subhead(context)),
        const SizedBox(height: 12),
        if (_items.isEmpty) AppleCard(child: Text('No tickets.', style: AppleTheme.footnote(context)))
        else ..._items.map((t) => _row(t as Map<String, dynamic>)),
      ])),
      _fab(_create),
    ]);
  }
  Widget _row(Map<String, dynamic> t) {
    final status = t['status']?.toString() ?? 'open';
    final c = _tc(status);
    return Padding(padding: const EdgeInsets.only(bottom: 12), child: AppleCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(t['subject']?.toString() ?? 'Ticket', style: AppleTheme.headline(context))),
        Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: c.withOpacity(0.14), borderRadius: BorderRadius.zero), child: Text(status, style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w700))),
      ]),
      if ((t['body']?.toString() ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(t['body'].toString(), style: AppleTheme.footnote(context))),
      const SizedBox(height: 8),
      Row(children: [
        if (t['priority'] == 'high') const Padding(padding: EdgeInsets.only(right: 8), child: Icon(CupertinoIcons.flag_fill, size: 14, color: AppleColors.orange)),
        const Spacer(),
        for (final s in const ['open', 'pending', 'closed']) if (s != status) Padding(padding: const EdgeInsets.only(left: 10), child: GestureDetector(
          onTap: () async { await widget.auth.apiPost('/api/v1/manage/crm/tickets/${t['id']}/status', {'status': s}); _load(); },
          child: Text(s, style: TextStyle(fontSize: 12, color: Palette.of(context).accent, fontWeight: FontWeight.w600)))),
      ]),
    ])));
  }
  Future<void> _create() async {
    final subject = TextEditingController();
    final body = TextEditingController();
    int pri = 1;
    final ok = await showFormSheet(context, title: 'New Ticket', builder: (setS) => [
      sheetField(subject, 'Subject', CupertinoIcons.exclamationmark_bubble),
      const SizedBox(height: 10),
      sheetField(body, 'Details', CupertinoIcons.text_alignleft),
      const SizedBox(height: 10),
      AppleSegmented(labels: const ['Low', 'Normal', 'High'], selected: pri, onChanged: (i) => setS(() => pri = i)),
    ], onSubmit: () async {
      if (subject.text.trim().isEmpty) return 'Subject required';
      try {
        await widget.auth.apiPost('/api/v1/manage/crm/tickets', {'subject': subject.text.trim(), 'body': body.text.trim(), 'priority': ['low', 'normal', 'high'][pri]});
        return null;
      } on ApiException catch (e) { return e.message; }
    });
    if (ok == true) { _toast('Ticket created'); _load(); }
  }
}

class _AffiliatesTab extends StatefulWidget {
  const _AffiliatesTab({required this.auth});
  final AuthService auth;
  @override
  State<_AffiliatesTab> createState() => _AffiliatesTabState();
}

class _AffiliatesTabState extends State<_AffiliatesTab> {
  bool _loading = true;
  List<dynamic> _items = [];
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { _items = (ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/crm/affiliates'))['affiliates'] as List?) ?? []; } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }
  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    return Stack(children: [
      RefreshIndicator(onRefresh: _load, child: ListView(padding: EdgeInsets.fromLTRB(hp, 8, hp, 100), children: [
        Text('${_items.length} affiliates', style: AppleTheme.subhead(context)),
        const SizedBox(height: 12),
        if (_items.isEmpty) AppleCard(child: Text('No affiliates yet.', style: AppleTheme.footnote(context)))
        else ..._items.map((a) => Padding(padding: const EdgeInsets.only(bottom: 12), child: AppleCard(child: Row(children: [
          Container(width: 40, height: 40, alignment: Alignment.center, decoration: BoxDecoration(color: AppleColors.purple.withOpacity(0.14), borderRadius: BorderRadius.zero), child: const Icon(CupertinoIcons.person_2_fill, color: AppleColors.purple, size: 18)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(a['name']?.toString() ?? 'Affiliate', style: AppleTheme.headline(context)),
            Text('Code ${a['code']} · ${a['commission_rate']}% · ${_money((a['pending'] as num?) ?? 0)} due', style: AppleTheme.footnote(context)),
          ])),
          GestureDetector(onTap: () async { await widget.auth.apiDelete('/api/v1/manage/crm/affiliates/${a['id']}'); _load(); }, child: const Icon(CupertinoIcons.trash, size: 18, color: AppleColors.red)),
        ])))),
      ])),
      _fab(_create),
    ]);
  }
  Future<void> _create() async {
    final name = TextEditingController();
    final email = TextEditingController();
    final code = TextEditingController();
    final rate = TextEditingController(text: '10');
    final ok = await showFormSheet(context, title: 'New Affiliate', builder: (setS) => [
      sheetField(name, 'Name', CupertinoIcons.person),
      const SizedBox(height: 10),
      sheetField(email, 'Email', CupertinoIcons.mail, keyboard: TextInputType.emailAddress),
      const SizedBox(height: 10),
      sheetField(code, 'Referral code (optional)', CupertinoIcons.tag),
      const SizedBox(height: 10),
      sheetField(rate, 'Commission rate (%)', CupertinoIcons.percent, keyboard: TextInputType.number),
    ], onSubmit: () async {
      if (name.text.trim().isEmpty) return 'Name required';
      try {
        await widget.auth.apiPost('/api/v1/manage/crm/affiliates', {'name': name.text.trim(), 'email': email.text.trim(), 'code': code.text.trim(), 'commission_rate': double.tryParse(rate.text.trim()) ?? 0});
        return null;
      } on ApiException catch (e) { return e.message; }
    });
    if (ok == true) { _toast('Affiliate added'); _load(); }
  }
}

class _WebhooksTab extends StatefulWidget {
  const _WebhooksTab({required this.auth});
  final AuthService auth;
  @override
  State<_WebhooksTab> createState() => _WebhooksTabState();
}

class _WebhooksTabState extends State<_WebhooksTab> {
  bool _loading = true;
  List<dynamic> _items = [];
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { _items = (ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/crm/webhooks'))['webhooks'] as List?) ?? []; } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }
  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    return Stack(children: [
      RefreshIndicator(onRefresh: _load, child: ListView(padding: EdgeInsets.fromLTRB(hp, 8, hp, 100), children: [
        Text('${_items.length} webhooks', style: AppleTheme.subhead(context)),
        const SizedBox(height: 12),
        if (_items.isEmpty) AppleCard(child: Text('No webhooks. Add an endpoint to receive CRM events.', style: AppleTheme.footnote(context)))
        else ..._items.map((w) => Padding(padding: const EdgeInsets.only(bottom: 12), child: AppleCard(child: Row(children: [
          const Icon(CupertinoIcons.link, color: AppleColors.teal),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(w['event']?.toString() ?? '', style: AppleTheme.headline(context)),
            Text(w['url']?.toString() ?? '', style: AppleTheme.footnote(context), maxLines: 1, overflow: TextOverflow.ellipsis),
          ])),
          GestureDetector(onTap: () async { await widget.auth.apiDelete('/api/v1/manage/crm/webhooks/${w['id']}'); _load(); }, child: const Icon(CupertinoIcons.trash, size: 18, color: AppleColors.red)),
        ])))),
      ])),
      _fab(_create),
    ]);
  }
  Future<void> _create() async {
    final url = TextEditingController();
    final event = TextEditingController(text: 'lead.created');
    final ok = await showFormSheet(context, title: 'New Webhook', builder: (setS) => [
      sheetField(url, 'Endpoint URL (https://…)', CupertinoIcons.link),
      const SizedBox(height: 10),
      sheetField(event, 'Event (e.g. lead.created)', CupertinoIcons.bolt),
    ], onSubmit: () async {
      if (!url.text.trim().startsWith('http')) return 'Valid URL required';
      try { await widget.auth.apiPost('/api/v1/manage/crm/webhooks', {'url': url.text.trim(), 'event': event.text.trim()}); return null; }
      on ApiException catch (e) { return e.message; }
    });
    if (ok == true) { _toast('Webhook added'); _load(); }
  }
}

// ===========================================================================
// Funnel
// ===========================================================================

class _FunnelTab extends StatefulWidget {
  const _FunnelTab({required this.auth});
  final AuthService auth;
  @override
  State<_FunnelTab> createState() => _FunnelTabState();
}

class _FunnelTabState extends State<_FunnelTab> {
  bool _loading = true;
  Map<String, dynamic> _d = {};
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { _d = ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/crm/funnel')); } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }
  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    final funnel = (_d['funnel'] as List?) ?? [];
    final total = ((_d['total'] as num?) ?? 0).toInt();
    final maxC = funnel.fold<int>(1, (m, e) => ((e['count'] as num?)?.toInt() ?? 0) > m ? (e['count'] as num).toInt() : m);
    return RefreshIndicator(onRefresh: _load, child: ListView(padding: EdgeInsets.fromLTRB(hp, 8, hp, 40), children: [
      Text('Conversion funnel', style: AppleTheme.subhead(context)),
      const SizedBox(height: 6),
      Text('${(_d['conversion_pct'] as num?)?.toStringAsFixed(1) ?? '0'}% converted · $total leads', style: AppleTheme.footnote(context)),
      const SizedBox(height: 16),
      ...funnel.map((e) {
        final m = e as Map<String, dynamic>;
        final count = (m['count'] as num?)?.toInt() ?? 0;
        final frac = (count / maxC).clamp(0.0, 1.0);
        return Padding(padding: const EdgeInsets.only(bottom: 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Expanded(child: Text(m['stage']?.toString() ?? '', style: AppleTheme.body(context))), Text('$count', style: AppleTheme.headline(context))]),
          const SizedBox(height: 6),
          ClipRRect(borderRadius: BorderRadius.zero, child: LinearProgressIndicator(value: frac, minHeight: 10, backgroundColor: Palette.of(context).card2, color: _statusColor(m['stage']?.toString() ?? ''))),
        ]));
      }),
    ]));
  }
}

// ===========================================================================
// My Day
// ===========================================================================

class _MyDayTab extends StatefulWidget {
  const _MyDayTab({required this.auth});
  final AuthService auth;
  @override
  State<_MyDayTab> createState() => _MyDayTabState();
}

class _MyDayTabState extends State<_MyDayTab> {
  bool _loading = true;
  Map<String, dynamic> _d = {};
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { _d = ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/crm/my-day')); } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }
  Future<void> _done(String id) async {
    try { await widget.auth.apiPost('/api/v1/manage/crm/tasks/$id/status', {'status': 'completed'}); _load(); } catch (_) {}
  }
  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    final tasks = (_d['tasks'] as List?) ?? [];
    Color bc(String b) => b == 'overdue' ? AppleColors.red : (b == 'today' ? AppleColors.orange : Palette.of(context).secondary);
    return RefreshIndicator(onRefresh: _load, child: ListView(padding: EdgeInsets.fromLTRB(hp, 8, hp, 40), children: [
      Text('${_d['overdue'] ?? 0} overdue · ${_d['today'] ?? 0} due today', style: AppleTheme.subhead(context)),
      const SizedBox(height: 14),
      if (tasks.isEmpty) AppleCard(child: Text('No open tasks. You\'re all caught up.', style: AppleTheme.footnote(context)))
      else ...tasks.map((t) {
        final m = t as Map<String, dynamic>;
        final b = m['bucket']?.toString() ?? 'upcoming';
        return Padding(padding: const EdgeInsets.only(bottom: 10), child: AppleCard(child: Row(children: [
          GestureDetector(onTap: () => _done(m['id'].toString()), child: Icon(CupertinoIcons.circle, color: bc(b))),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(m['title']?.toString() ?? 'Task', style: AppleTheme.body(context)),
            Text('${m['lead']} · ${_fmtD(m['due_at'])}', style: AppleTheme.footnote(context)),
          ])),
          Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: bc(b).withOpacity(0.14), borderRadius: BorderRadius.zero), child: Text(b, style: TextStyle(fontSize: 11, color: bc(b), fontWeight: FontWeight.w700))),
        ])));
      }),
    ]));
  }
}

// ===========================================================================
// Integrations (status + where to add the API key)
// ===========================================================================

class _IntegrationsTab extends StatefulWidget {
  const _IntegrationsTab({required this.auth});
  final AuthService auth;
  @override
  State<_IntegrationsTab> createState() => _IntegrationsTabState();
}

class _IntegrationsTabState extends State<_IntegrationsTab> {
  bool _loading = true;
  Map<String, dynamic> _d = {};
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { _d = ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/integrations')); } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }
  @override
  Widget build(BuildContext context) {
    final hp = MediaQuery.of(context).size.width > 700 ? 32.0 : 18.0;
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    final items = (_d['integrations'] as List?) ?? [];
    return RefreshIndicator(onRefresh: _load, child: ListView(padding: EdgeInsets.fromLTRB(hp, 8, hp, 40), children: [
      Text('${_d['live'] ?? 0}/${_d['total'] ?? 0} live · rest run in demo mode', style: AppleTheme.subhead(context)),
      const SizedBox(height: 14),
      ...items.map((e) {
        final m = e as Map<String, dynamic>;
        final live = m['status'] == 'live';
        final c = live ? AppleColors.green : AppleColors.orange;
        return Padding(padding: const EdgeInsets.only(bottom: 12), child: AppleCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(m['name']?.toString() ?? '', style: AppleTheme.headline(context))),
            Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3), decoration: BoxDecoration(color: c.withOpacity(0.14), borderRadius: BorderRadius.zero), child: Text(live ? 'LIVE' : 'DEMO', style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w800))),
          ]),
          const SizedBox(height: 4),
          Text(m['description']?.toString() ?? '', style: AppleTheme.footnote(context)),
          const SizedBox(height: 8),
          Row(children: [Icon(CupertinoIcons.gear_alt, size: 13, color: Palette.of(context).secondary), const SizedBox(width: 6), Expanded(child: Text('Set: ${m['env_var']}', style: AppleTheme.footnote(context).copyWith(fontFamily: 'monospace')))]),
          const SizedBox(height: 2),
          Row(children: [Icon(CupertinoIcons.arrow_right_circle, size: 13, color: Palette.of(context).secondary), const SizedBox(width: 6), Expanded(child: Text('Used in: ${m['used_in']}', style: AppleTheme.footnote(context)))]),
        ])));
      }),
      const SizedBox(height: 8),
      AppleCard(child: Text('Each integration works in DEMO mode (simulated, dummy data) until you set its env var in /opt/onrol/.env on the server, then restart. See INTEGRATIONS.md.', style: AppleTheme.footnote(context))),
    ]));
  }
}
