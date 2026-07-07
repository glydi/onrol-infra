import 'dart:async';

import 'package:flutter/cupertino.dart' hide Text;
import 'package:flutter/material.dart' hide Text;
import 'package:onrol_app/widgets/upper_text.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'live_session_screen.dart';
import 'login_screen.dart';

/// Restricted "Live Classes" portal for a live-host account: it can ONLY watch
/// live classes and answer student questions — nothing else (no courses, people,
/// uploads or settings). Tapping a session opens it in host mode.
class LiveHostPortalScreen extends StatefulWidget {
  const LiveHostPortalScreen({super.key, required this.auth});
  final AuthService auth;

  @override
  State<LiveHostPortalScreen> createState() => _LiveHostPortalScreenState();
}

class _LiveHostPortalScreenState extends State<LiveHostPortalScreen> {
  bool _loading = true;
  String? _err;
  List<Map<String, dynamic>> _sessions = [];
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    _load();
    _refresh = Timer.periodic(const Duration(seconds: 15), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet && mounted) setState(() { _loading = true; _err = null; });
    try {
      final d = ApiClient.decode(await widget.auth.apiGet('/api/v1/live-host/sessions'));
      _sessions = ((d['sessions'] as List?) ?? []).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (_) {
      if (!quiet) _err = 'Could not load live classes';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _logout() async {
    await widget.auth.logout();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => LoginScreen(auth: widget.auth)));
  }

  void _open(Map<String, dynamic> s) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LiveSessionScreen(
        auth: widget.auth,
        sessionId: s['id'].toString(),
        watermark: widget.auth.user?.email ?? 'host',
        title: s['title']?.toString() ?? 'Live Class',
        isHost: true,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SquareScope(
      child: Scaffold(
        backgroundColor: p.bg,
        appBar: AppBar(
          backgroundColor: p.bg.withOpacity(0.9),
          scrolledUnderElevation: 0,
          elevation: 0,
          title: Text('Live Classes', style: AppleTheme.headline(context)),
          actions: [
            IconButton(icon: Icon(CupertinoIcons.arrow_clockwise, color: p.accent), onPressed: _load),
            IconButton(icon: Icon(CupertinoIcons.square_arrow_right, color: p.secondary), onPressed: _logout),
          ],
        ),
        body: _loading
            ? const Center(child: CupertinoActivityIndicator())
            : _err != null
                ? Center(child: Text(_err!, style: AppleTheme.footnote(context)))
                : RefreshIndicator(
                    color: p.accent,
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
                      children: [
                        Text('Answer questions and watch the live class.', style: AppleTheme.subhead(context)),
                        const SizedBox(height: 14),
                        if (_sessions.isEmpty)
                          AppleCard(square: true, child: Text('No live classes scheduled.', style: AppleTheme.footnote(context)))
                        else
                          ..._sessions.map(_card),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _card(Map<String, dynamic> s) {
    final p = Palette.of(context);
    final start = DateTime.tryParse(s['starts_at']?.toString() ?? '')?.toLocal();
    final end = DateTime.tryParse(s['ends_at']?.toString() ?? '')?.toLocal();
    final now = DateTime.now();
    final live = start != null && now.isAfter(start) && (end == null || now.isBefore(end));
    final ended = end != null && now.isAfter(end);
    final waiting = (s['waiting'] as num?)?.toInt() ?? 0;
    final statusColor = live ? AppleColors.red : (ended ? p.secondary : AppleColors.blue);
    final statusText = live ? 'LIVE' : (ended ? 'Ended' : 'Upcoming');
    final time = start == null ? 'TBD' : '${_clock(start)} · ${start.day}/${start.month}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppleCard(
        square: true,
        onTap: () => _open(s),
        child: Row(children: [
          Container(
            width: 40, height: 40, alignment: Alignment.center,
            decoration: BoxDecoration(color: statusColor.withOpacity(0.14)),
            child: Icon(live ? CupertinoIcons.dot_radiowaves_left_right : CupertinoIcons.play_rectangle_fill, color: statusColor, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s['title']?.toString() ?? 'Live class', style: AppleTheme.headline(context), maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(['${s['course'] ?? ''}', time].where((e) => e.isNotEmpty).join(' · '), style: AppleTheme.footnote(context), maxLines: 1, overflow: TextOverflow.ellipsis),
          ])),
          if (waiting > 0) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: AppleColors.orange.withOpacity(0.15)),
              child: Text('$waiting Q', style: const TextStyle(color: AppleColors.orange, fontSize: 11, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 8),
          ],
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: statusColor.withOpacity(0.15)),
            child: Text(statusText, style: TextStyle(color: statusColor, fontSize: 10.5, fontWeight: FontWeight.w700)),
          ),
        ]),
      ),
    );
  }

  static String _clock(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
  }
}
