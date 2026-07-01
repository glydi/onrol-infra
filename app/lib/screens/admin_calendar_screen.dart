import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import '../widgets/ui.dart';

/// Admin calendar: view a month of events and add / edit / delete them. Events
/// are targeted (everyone / batch / role) and show up on students' calendars.
class AdminCalendarScreen extends StatefulWidget {
  const AdminCalendarScreen({super.key, required this.auth});
  final AuthService auth;

  @override
  State<AdminCalendarScreen> createState() => _AdminCalendarScreenState();
}

class _AdminCalendarScreenState extends State<AdminCalendarScreen> {
  bool _loading = true;
  final Map<String, List<Map<String, dynamic>>> _byDay = {};
  late DateTime _month;
  late DateTime _selected;

  static const _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  static const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _roles = ['student', 'instructor', 'manager'];

  String _dk(DateTime d) => '${d.year}-${d.month}-${d.day}';

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selected = DateTime(now.year, now.month, now.day);
    _month = DateTime(now.year, now.month);
    _load();
  }

  Future<void> _load() async {
    try {
      _byDay.clear();
      // Editable events (full detail).
      final r = await widget.auth.apiGet('/api/v1/manage/calendar');
      for (final e in ((ApiClient.decode(r)['events'] as List?) ?? []).map((e) => (e as Map).cast<String, dynamic>())) {
        final dt = DateTime.tryParse(e['starts_at']?.toString() ?? '')?.toLocal();
        if (dt == null) continue;
        _byDay.putIfAbsent(_dk(DateTime(dt.year, dt.month, dt.day)), () => []).add({...e, 'kind': 'event', '_dt': dt});
      }
      // Read-only items so the calendar is in sync with what students see:
      // live classes, deadlines, announcements.
      final f = await widget.auth.apiGet('/api/v1/manage/calendar/feed');
      for (final m in ((ApiClient.decode(f)['items'] as List?) ?? []).map((e) => (e as Map).cast<String, dynamic>())) {
        final dt = DateTime.tryParse(m['at']?.toString() ?? '')?.toLocal();
        if (dt == null) continue;
        _byDay.putIfAbsent(_dk(DateTime(dt.year, dt.month, dt.day)), () => []).add({...m, '_dt': dt});
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  // Event types the admin can pick (the "what" of an event).
  static const _eventTypes = <(String, String, IconData, Color)>[
    ('general', 'Event', CupertinoIcons.calendar, AppleColors.blue),
    ('batch_start', 'Batch Start', CupertinoIcons.person_3_fill, AppleColors.green),
    ('live', 'Live Class', CupertinoIcons.videocam_fill, AppleColors.red),
    ('exam', 'Exam / Test', CupertinoIcons.doc_text_fill, AppleColors.orange),
    ('holiday', 'Holiday', CupertinoIcons.sun_max_fill, Color(0xFF7C5CFC)),
    ('deadline', 'Deadline', CupertinoIcons.clock_fill, Color(0xFFE0A12A)),
    ('orientation', 'Orientation', CupertinoIcons.compass_fill, Color(0xFF18A999)),
    ('meeting', 'Meeting', CupertinoIcons.person_2_fill, Color(0xFF3A57E8)),
    ('result', 'Results', CupertinoIcons.chart_bar_fill, Color(0xFFEA4C89)),
    ('fee', 'Fee / Payment', CupertinoIcons.creditcard_fill, Color(0xFF2D7DF6)),
  ];

  ({IconData icon, Color color, String label}) _typeStyle(String key) {
    final t = _eventTypes.firstWhere((e) => e.$1 == key, orElse: () => _eventTypes.first);
    return (icon: t.$3, color: t.$4, label: t.$2);
  }

  // Style for any calendar item: events use their type; the read-only feed uses
  // its kind.
  ({IconData icon, Color color, String label}) _styleFor(Map<String, dynamic> m) {
    final kind = m['kind']?.toString() ?? 'event';
    if (kind == 'event') return _typeStyle(m['event_type']?.toString() ?? 'general');
    return _kindStyle(kind);
  }

  // Icon/colour/label per read-only feed item kind.
  ({IconData icon, Color color, String label}) _kindStyle(String kind) {
    switch (kind) {
      case 'session':
        return (icon: CupertinoIcons.videocam_fill, color: AppleColors.red, label: 'Live class');
      case 'assessment_due':
        return (icon: CupertinoIcons.doc_text_fill, color: AppleColors.orange, label: 'Deadline');
      case 'announcement':
        return (icon: CupertinoIcons.bell_fill, color: AppleColors.green, label: 'Announcement');
      default:
        return (icon: CupertinoIcons.calendar, color: AppleColors.blue, label: 'Event');
    }
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  void _shift(int d) => setState(() => _month = DateTime(_month.year, _month.month + d));

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CupertinoActivityIndicator());
    final p = Palette.of(context);
    final hp = MediaQuery.of(context).size.width > 720 ? 28.0 : 16.0;
    final selEvs = [...(_byDay[_dk(_selected)] ?? const <Map<String, dynamic>>[])]..sort((a, b) => (a['_dt'] as DateTime).compareTo(b['_dt'] as DateTime));
    return RefreshIndicator(
      color: p.accent,
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.fromLTRB(hp, 18, hp, 40),
        children: [
          Row(children: [
            Expanded(child: Text('Calendar', style: AppleTheme.largeTitle(context))),
            HoverTap(onTap: _load, child: Icon(CupertinoIcons.arrow_clockwise, color: p.accent, size: 24)),
          ]),
          Text('Schedule events for students, batches or roles', style: AppleTheme.subhead(context)),
          const SizedBox(height: 16),
          PrimaryButton(label: 'Add Event', icon: CupertinoIcons.add, square: true, onPressed: () => _addOrEdit(day: _selected)),
          const SizedBox(height: 18),
          // Month navigator.
          Row(children: [
            _navBtn(CupertinoIcons.chevron_left, () => _shift(-1)),
            Expanded(child: Center(child: Text('${_months[_month.month - 1]} ${_month.year}', style: AppleTheme.headline(context)))),
            _navBtn(CupertinoIcons.chevron_right, () => _shift(1)),
          ]),
          const SizedBox(height: 12),
          Row(children: _wd.map((w) => Expanded(child: Center(child: Text(w, style: AppleTheme.footnote(context))))).toList()),
          const SizedBox(height: 4),
          _grid(),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: Text('${_wd[(_selected.weekday - 1) % 7]}, ${_months[_selected.month - 1]} ${_selected.day}', style: AppleTheme.headline(context))),
            Text('${selEvs.length} ${selEvs.length == 1 ? 'item' : 'items'}', style: AppleTheme.footnote(context).copyWith(color: p.accent)),
          ]),
          const SizedBox(height: 10),
          if (selEvs.isEmpty)
            AppleCard(square: true, child: Text('Nothing on this day. Tap “Add Event”.', style: AppleTheme.footnote(context)))
          else
            ...selEvs.map(_itemCard),
        ],
      ),
    );
  }

  Widget _navBtn(IconData ic, VoidCallback onTap) => HoverTap(
        onTap: onTap,
        child: Container(width: 38, height: 38, alignment: Alignment.center, decoration: BoxDecoration(color: Palette.of(context).accent.withOpacity(0.10)), child: Icon(ic, size: 18, color: Palette.of(context).accent)),
      );

  Widget _grid() {
    final p = Palette.of(context);
    final first = DateTime(_month.year, _month.month, 1);
    final lead = (first.weekday - 1) % 7;
    final days = DateTime(_month.year, _month.month + 1, 0).day;
    final cells = <DateTime?>[];
    for (var i = 0; i < lead; i++) cells.add(null);
    for (var d = 1; d <= days; d++) cells.add(DateTime(_month.year, _month.month, d));
    while (cells.length % 7 != 0) cells.add(null);
    final now = DateTime.now();
    final rows = <Widget>[];
    for (var i = 0; i < cells.length; i += 7) {
      rows.add(Row(children: [
        for (var j = 0; j < 7; j++)
          Expanded(child: Builder(builder: (_) {
            final d = cells[i + j];
            if (d == null) return const SizedBox(height: 46);
            final isToday = d.year == now.year && d.month == now.month && d.day == now.day;
            final isSel = d == _selected;
            final n = (_byDay[_dk(d)] ?? const []).length;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _selected = d),
              child: Container(
                height: 46,
                margin: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: isSel ? p.accent : (isToday ? p.accent.withOpacity(0.12) : Colors.transparent),
                  border: isToday && !isSel ? Border.all(color: p.accent.withOpacity(0.6)) : null,
                ),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text('${d.day}', style: AppleTheme.body(context).copyWith(color: isSel ? Colors.white : null, fontWeight: isSel || isToday ? FontWeight.w700 : FontWeight.w500)),
                  const SizedBox(height: 3),
                  SizedBox(height: 5, child: n == 0 ? null : Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                    for (final m in (_byDay[_dk(d)] ?? const []).take(3))
                      Container(width: 5, height: 5, margin: const EdgeInsets.symmetric(horizontal: 1), decoration: BoxDecoration(color: isSel ? Colors.white : _styleFor(m).color, shape: BoxShape.circle)),
                  ])),
                ]),
              ),
            );
          })),
      ]));
    }
    return Column(children: rows);
  }

  Widget _itemCard(Map<String, dynamic> e) {
    final kind = e['kind']?.toString() ?? 'event';
    final isEvent = kind == 'event';
    final st = _styleFor(e);
    final dt = e['_dt'] as DateTime;
    final end = DateTime.tryParse(e['ends_at']?.toString() ?? '')?.toLocal();
    final loc = e['location']?.toString() ?? '';
    final course = e['course']?.toString() ?? '';
    final desc = e['description']?.toString() ?? '';
    final time = end == null ? _clock(dt) : '${_clock(dt)} – ${_clock(end)}';
    final sub = isEvent
        ? [st.label, time, if (loc.isNotEmpty) loc, _audienceLabel(e)].join(' · ')
        : [st.label, if (course.isNotEmpty) course, time].where((x) => x.isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppleCard(
        square: true,
        onTap: isEvent ? () => _addOrEdit(ev: e) : null,
        child: Row(children: [
          Container(width: 40, height: 40, alignment: Alignment.center, decoration: BoxDecoration(color: st.color.withOpacity(0.12)), child: Icon(st.icon, color: st.color, size: 20)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e['title']?.toString() ?? st.label, style: AppleTheme.headline(context), maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(sub, style: AppleTheme.footnote(context), maxLines: 1, overflow: TextOverflow.ellipsis),
            if (isEvent && desc.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(desc, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppleTheme.footnote(context))),
          ])),
          if (isEvent) HoverTap(onTap: () => _delete(e), child: Icon(CupertinoIcons.trash, size: 18, color: Palette.of(context).secondary)),
        ]),
      ),
    );
  }

  String _audienceLabel(Map<String, dynamic> e) {
    switch (e['audience']?.toString()) {
      case 'batch':
        return 'Batch ${e['batch_number'] ?? '?'}';
      case 'role':
        final r = e['role']?.toString() ?? '';
        return r.isEmpty ? 'Role' : '${r[0].toUpperCase()}${r.substring(1)}s';
      default:
        return 'Everyone';
    }
  }

  Future<void> _delete(Map<String, dynamic> e) async {
    final yes = await showSquareConfirm(context, title: 'Delete event', message: 'Delete “${e['title']}”? This removes it from everyone’s calendar.', confirmLabel: 'Delete', destructive: true);
    if (!yes) return;
    try {
      await widget.auth.apiDelete('/api/v1/manage/calendar/${e['id']}');
      _toast('Event deleted');
      _load();
    } catch (_) {
      _toast('Could not delete');
    }
  }

  Future<void> _addOrEdit({Map<String, dynamic>? ev, DateTime? day}) async {
    final isEdit = ev != null;
    final title = TextEditingController(text: ev?['title']?.toString() ?? '');
    final desc = TextEditingController(text: ev?['description']?.toString() ?? '');
    final loc = TextEditingController(text: ev?['location']?.toString() ?? '');
    final batch = TextEditingController(text: ev?['batch_number']?.toString() ?? '');
    final base = day ?? _selected;
    final nowT = TimeOfDay.now();
    DateTime start = DateTime.tryParse(ev?['starts_at']?.toString() ?? '')?.toLocal() ?? DateTime(base.year, base.month, base.day, nowT.hour, nowT.minute);
    DateTime end = DateTime.tryParse(ev?['ends_at']?.toString() ?? '')?.toLocal() ?? start.add(const Duration(hours: 1));
    bool hasEnd = ev != null && (ev['ends_at']?.toString().isNotEmpty ?? false);
    int aud = const {'all': 0, 'batch': 1, 'role': 2}[ev?['audience']?.toString() ?? 'all'] ?? 0;
    int roleIdx = const {'student': 0, 'instructor': 1, 'manager': 2}[ev?['role']?.toString() ?? 'student'] ?? 0;
    String etype = ev?['event_type']?.toString() ?? 'general';

    final ok = await showFormSheet(context, square: true, title: isEdit ? 'Edit Event' : 'Add Event', builder: (setS) => [
      _lbl('What is it?'),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final t in _eventTypes) _typeChip(t.$1, t.$2, t.$3, t.$4, etype == t.$1, () => setS(() => etype = t.$1)),
      ]),
      const SizedBox(height: 14),
      sheetField(title, 'Title (e.g. Batch 7 starts)', CupertinoIcons.textformat),
      const SizedBox(height: 10),
      sheetField(desc, 'Description (optional)', CupertinoIcons.text_alignleft),
      const SizedBox(height: 10),
      sheetField(loc, 'Location / link (optional)', CupertinoIcons.location),
      const SizedBox(height: 14),
      _lbl('Starts'),
      _dtField(start, (d) => setS(() => start = d)),
      const SizedBox(height: 10),
      Row(children: [Expanded(child: _lbl('Add an end time')), CupertinoSwitch(value: hasEnd, onChanged: (v) => setS(() => hasEnd = v))]),
      if (hasEnd) ...[const SizedBox(height: 4), _dtField(end, (d) => setS(() => end = d))],
      const SizedBox(height: 14),
      _lbl('Who can see it'),
      AppleSegmented(square: true, labels: const ['Everyone', 'Batch', 'Role'], selected: aud, onChanged: (i) => setS(() => aud = i)),
      if (aud == 1) ...[const SizedBox(height: 10), sheetField(batch, 'Batch number', CupertinoIcons.number, keyboard: TextInputType.number)],
      if (aud == 2) ...[const SizedBox(height: 10), AppleSegmented(square: true, labels: const ['Students', 'Instructors', 'Managers'], selected: roleIdx, onChanged: (i) => setS(() => roleIdx = i))],
    ], onSubmit: () async {
      if (title.text.trim().isEmpty) return 'Title required';
      if (aud == 1 && int.tryParse(batch.text.trim()) == null) return 'Enter a batch number';
      final body = <String, dynamic>{
        'title': title.text.trim(),
        'description': desc.text.trim(),
        'location': loc.text.trim(),
        'starts_at': start.toUtc().toIso8601String(),
        'ends_at': hasEnd ? end.toUtc().toIso8601String() : '',
        'audience': const ['all', 'batch', 'role'][aud],
        'event_type': etype,
      };
      if (aud == 1) body['batch_number'] = int.tryParse(batch.text.trim());
      if (aud == 2) body['role'] = _roles[roleIdx];
      try {
        if (isEdit) {
          await widget.auth.apiPatch('/api/v1/manage/calendar/${ev['id']}', body);
        } else {
          await widget.auth.apiPost('/api/v1/manage/calendar', body);
        }
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) {
      _toast(isEdit ? 'Event updated' : 'Event added');
      _load();
    }
  }

  Widget _lbl(String t) => Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(t, style: AppleTheme.footnote(context)));

  Widget _typeChip(String key, String label, IconData icon, Color color, bool sel, VoidCallback onTap) {
    final p = Palette.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        decoration: BoxDecoration(
          color: sel ? color.withOpacity(0.16) : p.card2,
          border: Border.all(color: sel ? color : p.separator, width: sel ? 1.4 : 1),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(label, style: AppleTheme.footnote(context).copyWith(color: sel ? color : null, fontWeight: sel ? FontWeight.w700 : FontWeight.w500)),
        ]),
      ),
    );
  }

  Widget _dtField(DateTime value, ValueChanged<DateTime> onPick) {
    final p = Palette.of(context);
    return GestureDetector(
      onTap: () async {
        final d = await showDatePicker(context: context, initialDate: value, firstDate: DateTime(2020), lastDate: DateTime.now().add(const Duration(days: 1095)));
        if (d == null) return;
        if (!mounted) return;
        final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(value));
        if (t == null) return;
        onPick(DateTime(d.year, d.month, d.day, t.hour, t.minute));
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(color: p.card2),
        child: Row(children: [
          Icon(CupertinoIcons.calendar, size: 19, color: p.secondary),
          const SizedBox(width: 12),
          Expanded(child: Text('${_wd[(value.weekday - 1) % 7]}, ${_months[value.month - 1]} ${value.day} · ${_clock(value)}', style: AppleTheme.body(context))),
          Icon(CupertinoIcons.chevron_right, size: 16, color: p.secondary),
        ]),
      ),
    );
  }

  static String _clock(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final ampm = d.hour < 12 ? 'AM' : 'PM';
    return '$h:${d.minute.toString().padLeft(2, '0')} $ampm';
  }
}
