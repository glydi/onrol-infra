import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import '../widgets/ui.dart';

// Bright orange-peach palette + grain — matches the rest of the app.
const _accent = Color(0xFFFF6A2C);
const _accentGrad = LinearGradient(colors: [Color(0xFFFFB877), Color(0xFFFF7A33), Color(0xFFFF5421)], begin: Alignment.topLeft, end: Alignment.bottomRight);
const _bg = Color(0xFFFFF6EF);
const _panel = Color(0xFFFFFCF8);
const _rail = Color(0xFFFFEDE0);
const _ink = Color(0xFF1A1A2E);
const _muted = Color(0xFF8C8782);
const _line = Color(0xFFFFE0CC);

/// Discord-like community forum: a rail of servers (global / course / batch),
/// channels within the selected server, and a live message stream + composer.
/// Staff can create and delete servers and channels.
class ForumScreen extends StatefulWidget {
  const ForumScreen({super.key, required this.auth});
  final AuthService auth;
  @override
  State<ForumScreen> createState() => _ForumScreenState();
}

class _ForumScreenState extends State<ForumScreen> {
  List<dynamic> _servers = [];
  bool _loading = true;
  String? _err;
  int _server = 0; // index into _servers
  String? _channelId;
  List<dynamic> _messages = [];
  bool _loadingMsgs = false;
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  Timer? _poll;

  bool get _staff {
    final r = widget.auth.user?.role;
    return r == 'instructor' || r == 'manager' || r == 'superadmin';
  }

  Map<String, dynamic>? get _curServer => (_servers.isNotEmpty && _server < _servers.length) ? _servers[_server] as Map<String, dynamic> : null;
  List get _channels => (_curServer?['channels'] as List?) ?? const [];

  @override
  void initState() {
    super.initState();
    _loadServers();
    // Light polling so new messages appear without a manual refresh.
    _poll = Timer.periodic(const Duration(seconds: 4), (_) {
      if (_channelId != null && mounted) _loadMessages(silent: true);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadServers() async {
    try {
      final m = ApiClient.decode(await widget.auth.apiGet('/api/v1/me/community/servers'));
      if (!mounted) return;
      setState(() {
        _servers = (m['servers'] as List?) ?? [];
        _loading = false;
        _err = null;
        if (_server >= _servers.length) _server = 0;
      });
      _selectFirstChannel();
    } catch (_) {
      if (mounted) setState(() { _loading = false; _err = 'Could not load communities.'; });
    }
  }

  void _selectFirstChannel() {
    final ch = _channels;
    if (ch.isNotEmpty) {
      _channelId = (ch.first as Map)['id'].toString();
      _loadMessages();
    } else {
      setState(() { _channelId = null; _messages = []; });
    }
  }

  Future<void> _loadMessages({bool silent = false}) async {
    final id = _channelId;
    if (id == null) return;
    if (!silent) setState(() => _loadingMsgs = true);
    try {
      final m = ApiClient.decode(await widget.auth.apiGet('/api/v1/me/community/channels/$id/messages'));
      if (!mounted || _channelId != id) return;
      final list = (m['messages'] as List?) ?? [];
      final atBottom = !_scroll.hasClients || _scroll.position.pixels >= _scroll.position.maxScrollExtent - 80;
      setState(() { _messages = list; _loadingMsgs = false; });
      if (atBottom) _jumpToBottomSoon();
    } catch (_) {
      if (mounted && !silent) setState(() => _loadingMsgs = false);
    }
  }

  void _jumpToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _send() async {
    final body = _composer.text.trim();
    final id = _channelId;
    if (body.isEmpty || id == null) return;
    _composer.clear();
    try {
      await widget.auth.apiPost('/api/v1/me/community/channels/$id/messages', {'body': body});
      await _loadMessages(silent: true);
      _jumpToBottomSoon();
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't send")));
    }
  }

  void _pickServer(int i) {
    setState(() { _server = i; _channelId = null; _messages = []; });
    _selectFirstChannel();
  }

  void _pickChannel(String id) {
    setState(() { _channelId = id; _messages = []; });
    _loadMessages();
  }

  // ---- Staff actions -------------------------------------------------------

  Future<void> _createServer() async {
    final name = TextEditingController();
    final icon = TextEditingController();
    final batch = TextEditingController();
    int scope = 0; // 0 global, 1 course, 2 batch
    const scopes = ['global', 'course', 'batch'];
    List<dynamic> courses = [];
    String? courseId;
    try {
      courses = (ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/courses'))['courses'] as List?) ?? [];
    } catch (_) {}
    final ok = await showFormSheet(context, square: true, title: 'New community server', builder: (setS) {
      return [
        sheetField(name, 'Server name (e.g. AI Architects)', CupertinoIcons.number),
        const SizedBox(height: 10),
        sheetField(icon, 'Icon — an emoji or letter (optional)', CupertinoIcons.smiley),
        const SizedBox(height: 12),
        Text('Who can join', style: AppleTheme.footnote(context)),
        const SizedBox(height: 6),
        AppleSegmented(square: true, labels: const ['Global', 'Course', 'Batch'], selected: scope, onChanged: (i) => setS(() => scope = i)),
        if (scope != 0) ...[
          const SizedBox(height: 12),
          Text('Course', style: AppleTheme.footnote(context)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in courses)
              GestureDetector(
                onTap: () => setS(() => courseId = c['id'].toString()),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: courseId == c['id'].toString() ? _accent.withValues(alpha: 0.16) : _rail,
                    border: Border.all(color: courseId == c['id'].toString() ? _accent : _line),
                  ),
                  child: Text(c['title']?.toString() ?? 'Course', style: AppleTheme.footnote(context)),
                ),
              ),
          ]),
        ],
        if (scope == 2) ...[
          const SizedBox(height: 12),
          sheetField(batch, 'Batch number (e.g. 1)', CupertinoIcons.number, keyboard: TextInputType.number),
        ],
      ];
    }, onSubmit: () async {
      if (name.text.trim().isEmpty) return 'Name required';
      if (scope != 0 && courseId == null) return 'Pick a course';
      if (scope == 2 && int.tryParse(batch.text.trim()) == null) return 'Batch number required';
      try {
        await widget.auth.apiPost('/api/v1/manage/community/servers', {
          'name': name.text.trim(),
          'scope': scopes[scope],
          'icon': icon.text.trim(),
          if (scope != 0) 'course_id': courseId,
          if (scope == 2) 'batch_number': int.parse(batch.text.trim()),
        });
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) _loadServers();
  }

  Future<void> _addChannel() async {
    final s = _curServer;
    if (s == null) return;
    final name = TextEditingController();
    final ok = await showFormSheet(context, square: true, title: 'New channel',
        builder: (_) => [sheetField(name, 'Channel name (e.g. announcements)', CupertinoIcons.number_circle)],
        onSubmit: () async {
      if (name.text.trim().isEmpty) return 'Name required';
      try {
        await widget.auth.apiPost('/api/v1/manage/community/servers/${s['id']}/channels', {'name': name.text.trim()});
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) _loadServers();
  }

  Future<void> _deleteServer() async {
    final s = _curServer;
    if (s == null) return;
    final yes = await showSquareConfirm(context,
        title: 'Delete server', message: 'Delete "${s['name']}" and all its channels & messages?',
        confirmLabel: 'Delete', destructive: true);
    if (!yes) return;
    try {
      await widget.auth.apiDelete('/api/v1/manage/community/servers/${s['id']}');
      setState(() => _server = 0);
      _loadServers();
    } catch (_) {}
  }

  // ---- UI ------------------------------------------------------------------

  // Opens like the app's other panels: a frosted floating card over a blurred,
  // dimmed dashboard (tap outside to close).
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final kb = MediaQuery.of(context).viewInsets.bottom;
    final phone = size.shortestSide < 600;
    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      body: Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).maybePop(),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: Container(color: Colors.black.withOpacity(0.34)),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(bottom: kb),
          child: Align(
            alignment: phone ? Alignment.topCenter : Alignment.center,
            child: SizedBox(
              width: phone ? size.width : (size.width * 0.97).clamp(0.0, 1180.0),
              height: phone ? (size.height - kb) : ((size.height - kb) * 0.97).clamp(0.0, 960.0),
              child: _card(phone),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _card(bool phone) {
    final cardW = phone ? MediaQuery.of(context).size.width : (MediaQuery.of(context).size.width * 0.97).clamp(0.0, 1180.0);
    final wide = cardW >= 820;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.zero,
          boxShadow: phone ? const [] : [BoxShadow(color: Colors.black.withOpacity(0.25), blurRadius: 48, offset: const Offset(0, 22))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.zero,
          child: Container(
            color: _bg,
            child: Column(children: [
              _header(phone),
              Expanded(
                child: Stack(children: [
                  Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _Grain()))),
                  _loading
                      ? const Center(child: CupertinoActivityIndicator())
                      : _servers.isEmpty
                          ? _empty()
                          : (wide ? _wide() : _narrow()),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  // Frosted gradient header matching the app's panel chrome.
  Widget _header(bool phone) {
    final topPad = phone ? MediaQuery.of(context).padding.top : 0.0;
    Widget chip(IconData icon, VoidCallback onTap) => GestureDetector(
          onTap: onTap,
          child: Container(
            width: 34, height: 34, alignment: Alignment.center,
            decoration: BoxDecoration(color: _accent.withOpacity(0.12), borderRadius: BorderRadius.zero, border: Border.all(color: _accent.withOpacity(0.25))),
            child: Icon(icon, size: 20, color: _accent),
          ),
        );
    return Container(
      padding: EdgeInsets.fromLTRB(14, 16 + topPad, 14, 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Colors.white.withOpacity(0.6), Colors.white.withOpacity(0.3)]),
        border: const Border(bottom: BorderSide(color: _line)),
      ),
      child: Row(children: [
        chip(CupertinoIcons.chevron_back, () => Navigator.of(context).maybePop()),
        const SizedBox(width: 12),
        const Icon(CupertinoIcons.bubble_left_bubble_right_fill, size: 24, color: _accent),
        const SizedBox(width: 12),
        Expanded(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Community', maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.ibmPlexMono(fontSize: 18, fontWeight: FontWeight.w800, color: _ink)),
            Text('Servers, channels & chat', maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.ibmPlexMono(fontSize: 12, color: _muted)),
          ]),
        ),
        if (_staff) chip(CupertinoIcons.add, _createServer),
      ]),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(CupertinoIcons.chat_bubble_2_fill, size: 40, color: _muted),
            const SizedBox(height: 12),
            Text(_err ?? 'No communities yet.', textAlign: TextAlign.center, style: GoogleFonts.ibmPlexMono(fontSize: 14, color: _muted)),
            if (_staff) ...[
              const SizedBox(height: 16),
              _pill('Create the first server', _createServer),
            ],
          ]),
        ),
      );

  Widget _wide() => Row(children: [
        _serverRail(),
        Container(width: 1, color: _line),
        SizedBox(width: 210, child: _channelPane()),
        Container(width: 1, color: _line),
        Expanded(child: _chatPane()),
      ]);

  Widget _narrow() => Column(children: [
        SizedBox(height: 64, child: _serverRail(horizontal: true)),
        Container(height: 1, color: _line),
        _channelStrip(),
        Container(height: 1, color: _line),
        Expanded(child: _chatPane()),
      ]);

  // Vertical (or horizontal) rail of server icons.
  Widget _serverRail({bool horizontal = false}) {
    final items = <Widget>[
      for (var i = 0; i < _servers.length; i++) _serverIcon(i),
      if (_staff) _railAdd(),
    ];
    return Container(
      color: _rail,
      padding: const EdgeInsets.all(8),
      child: horizontal
          ? ListView(scrollDirection: Axis.horizontal, children: [for (final w in items) Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: w)])
          : SizedBox(width: 56, child: ListView(children: [for (final w in items) Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: w)])),
    );
  }

  Widget _serverIcon(int i) {
    final s = _servers[i] as Map<String, dynamic>;
    final sel = i == _server;
    final icon = (s['icon']?.toString().trim() ?? '');
    final label = icon.isNotEmpty ? icon : (s['name']?.toString().isNotEmpty == true ? s['name'].toString()[0].toUpperCase() : '#');
    return GestureDetector(
      onTap: () => _pickServer(i),
      child: Container(
        width: 46, height: 46, alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: sel ? _accentGrad : null,
          color: sel ? null : _panel,
          borderRadius: BorderRadius.zero,
          border: Border.all(color: sel ? Colors.transparent : _line),
        ),
        child: Text(label, style: GoogleFonts.ibmPlexMono(fontSize: 18, fontWeight: FontWeight.w800, color: sel ? Colors.white : _ink)),
      ),
    );
  }

  Widget _railAdd() => GestureDetector(
        onTap: _createServer,
        child: Container(
          width: 46, height: 46, alignment: Alignment.center,
          decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.zero, border: Border.all(color: _line)),
          child: const Icon(CupertinoIcons.add, size: 20, color: _accent),
        ),
      );

  // Channel list (wide).
  Widget _channelPane() {
    final s = _curServer;
    return Container(
      color: _panel,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 10, 10),
          child: Row(children: [
            Expanded(child: Text(s?['name']?.toString() ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.ibmPlexMono(fontSize: 15, fontWeight: FontWeight.w800, color: _ink))),
            if (_staff) ...[
              GestureDetector(onTap: _addChannel, child: const Icon(CupertinoIcons.add, size: 18, color: _accent)),
              const SizedBox(width: 10),
              GestureDetector(onTap: _deleteServer, child: const Icon(CupertinoIcons.trash, size: 16, color: Color(0xFFCC5B4D))),
            ],
          ]),
        ),
        _scopeBadge(s),
        const SizedBox(height: 4),
        Expanded(
          child: ListView(padding: const EdgeInsets.symmetric(horizontal: 8), children: [
            for (final ch in _channels) _channelTile(ch as Map<String, dynamic>),
          ]),
        ),
      ]),
    );
  }

  Widget _scopeBadge(Map<String, dynamic>? s) {
    if (s == null) return const SizedBox.shrink();
    final scope = s['scope']?.toString() ?? 'global';
    final label = scope == 'global'
        ? 'Everyone'
        : scope == 'course'
            ? (s['course']?.toString().isNotEmpty == true ? s['course'].toString() : 'Course')
            : '${s['course'] ?? 'Course'} · Batch ${s['batch_number'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.ibmPlexMono(fontSize: 11, color: _muted)),
    );
  }

  Widget _channelTile(Map<String, dynamic> ch) {
    final id = ch['id'].toString();
    final sel = id == _channelId;
    return GestureDetector(
      onTap: () => _pickChannel(id),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(color: sel ? _accent.withValues(alpha: 0.12) : Colors.transparent, borderRadius: BorderRadius.zero),
        child: Row(children: [
          Text('#', style: GoogleFonts.ibmPlexMono(fontSize: 15, fontWeight: FontWeight.w800, color: sel ? _accent : _muted)),
          const SizedBox(width: 8),
          Expanded(child: Text(ch['name']?.toString() ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.ibmPlexMono(fontSize: 14, fontWeight: sel ? FontWeight.w700 : FontWeight.w500, color: sel ? _ink : _muted))),
        ]),
      ),
    );
  }

  // Channel chips (narrow).
  Widget _channelStrip() => Container(
        color: _panel,
        height: 46,
        child: Row(children: [
          Expanded(
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
              for (final ch in _channels)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 7),
                  child: GestureDetector(
                    onTap: () => _pickChannel(ch['id'].toString()),
                    child: Container(
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: ch['id'].toString() == _channelId ? _accent.withValues(alpha: 0.14) : _rail,
                        borderRadius: BorderRadius.zero,
                      ),
                      child: Text('#${ch['name']}', style: GoogleFonts.ibmPlexMono(fontSize: 13, fontWeight: FontWeight.w600, color: _ink)),
                    ),
                  ),
                ),
            ]),
          ),
          if (_staff) IconButton(icon: const Icon(CupertinoIcons.add, size: 18, color: _accent), onPressed: _addChannel),
        ]),
      );

  Widget _chatPane() {
    if (_channelId == null) {
      return Center(child: Text('No channels yet.', style: GoogleFonts.ibmPlexMono(fontSize: 13, color: _muted)));
    }
    return Column(children: [
      Expanded(
        child: _loadingMsgs && _messages.isEmpty
            ? const Center(child: CupertinoActivityIndicator())
            : _messages.isEmpty
                ? Center(child: Text('No messages yet — say hi 👋', style: GoogleFonts.ibmPlexMono(fontSize: 13, color: _muted)))
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    itemCount: _messages.length,
                    itemBuilder: (ctx, i) => _bubble(_messages[i] as Map<String, dynamic>),
                  ),
      ),
      _composerBar(),
    ]);
  }

  Future<void> _deleteMessage(String id) async {
    final yes = await showSquareConfirm(context, title: 'Delete message', message: 'Remove this message?', confirmLabel: 'Delete', destructive: true);
    if (!yes) return;
    try {
      await widget.auth.apiDelete('/api/v1/me/community/messages/$id');
      await _loadMessages(silent: true);
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't delete")));
    }
  }

  Widget _bubble(Map<String, dynamic> m) {
    final mine = m['mine'] == true;
    final name = m['name']?.toString().trim().isNotEmpty == true ? m['name'].toString() : 'Member';
    return GestureDetector(
      // Author can delete their own; staff can moderate anyone's.
      onLongPress: (mine || _staff) ? () => _deleteMessage(m['id'].toString()) : null,
      child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Avatar(name: name, size: 34),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(mine ? 'You' : name, style: GoogleFonts.ibmPlexMono(fontSize: 12.5, fontWeight: FontWeight.w700, color: mine ? _accent : _ink)),
              const SizedBox(width: 8),
              Text(_fmt(m['at']?.toString()), style: GoogleFonts.ibmPlexMono(fontSize: 10.5, color: _muted)),
            ]),
            const SizedBox(height: 2),
            Text(m['body']?.toString() ?? '', style: GoogleFonts.ibmPlexMono(fontSize: 14, color: _ink, height: 1.35)),
          ]),
        ),
      ]),
    ),
    );
  }

  Widget _composerBar() => Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        color: _panel,
        child: Row(children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(color: _bg, borderRadius: BorderRadius.zero, border: Border.all(color: _line)),
              child: TextField(
                controller: _composer,
                minLines: 1,
                maxLines: 4,
                style: GoogleFonts.ibmPlexMono(fontSize: 14, color: _ink),
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(border: InputBorder.none, isDense: true, contentPadding: const EdgeInsets.symmetric(vertical: 12), hintText: 'Message…', hintStyle: GoogleFonts.ibmPlexMono(fontSize: 14, color: _muted)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _send,
            child: Container(
              width: 44, height: 44, alignment: Alignment.center,
              decoration: const BoxDecoration(gradient: _accentGrad, shape: BoxShape.circle),
              child: const Icon(CupertinoIcons.arrow_up, color: Colors.white, size: 20),
            ),
          ),
        ]),
      );

  Widget _pill(String label, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          decoration: BoxDecoration(gradient: _accentGrad, borderRadius: BorderRadius.zero),
          child: Text(label, style: GoogleFonts.ibmPlexMono(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
        ),
      );

  String _fmt(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '$h:${dt.minute.toString().padLeft(2, '0')} $ampm';
  }
}

/// Faint static film-grain overlay (matches the rest of the app).
class _Grain extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(7);
    final paint = Paint();
    const base = Color(0xFF5A4A40);
    final count = (size.width * size.height / 900).clamp(0, 12000).toInt();
    for (var i = 0; i < count; i++) {
      paint.color = base.withValues(alpha: 0.028 * rnd.nextDouble());
      canvas.drawRect(Rect.fromLTWH(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height, 1.1, 1.1), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _Grain oldDelegate) => false;
}
