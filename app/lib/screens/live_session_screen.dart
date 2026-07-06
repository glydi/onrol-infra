import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart' hide Config;

import '../config.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../widgets/live_player.dart';

/// The "live room" for a simulated-live session (a recorded video streamed as if
/// it were live): a pre-start lobby + countdown, a time-locked player, and a
/// Q&A channel. Questions go PRIVATELY to the host; the host answers each asker.
/// In host mode (admin) there's no player — just the question queue to answer.
class LiveSessionScreen extends StatefulWidget {
  const LiveSessionScreen({super.key, required this.auth, required this.sessionId, required this.watermark, this.title = 'Live Class', this.isHost = false});
  final AuthService auth;
  final String sessionId;
  final String watermark;
  final String title;
  // Host (admin) control view: no player; sees the full question queue and
  // answers each student directly.
  final bool isHost;

  @override
  State<LiveSessionScreen> createState() => _LiveSessionScreenState();
}

class _LiveSessionScreenState extends State<LiveSessionScreen> {
  static const _orange = Color(0xFFFF4F2B);
  static const _bg = Color(0xFF0B0B0D);
  static const _panel = Color(0xFF15151A);

  Timer? _stateTimer, _qaTimer, _hbTimer, _tick, _chatTimer;

  // Server state.
  String _status = 'upcoming'; // upcoming | preparing | live | ended
  String _title = '';
  String _course = '';
  int _viewers = 0;
  bool _qaOn = true;
  String? _playlistUrl; // absolute, set once live
  String _startImage = ''; // 16:9 shown in place of the video before the class
  String _endImage = ''; // 16:9 shown in place of the video after it ends
  final Map<String, Widget> _coverCache = {}; // built cover widgets, cached by src
  DateTime? _startsAt;
  int _startEpochMs = 0; // scheduled start (UTC ms) — drives time-locked playback
  int _skewMs = 0; // server_now - device_now: normalizes a wrong device clock to the server
  bool _loaded = false;
  String? _fatal;

  // Q&A.
  final List<Map<String, dynamic>> _questions = [];
  final _qaCtl = TextEditingController();
  bool _sendingQa = false;

  // Mentor broadcasts (host → all viewers), shown to everyone in the room.
  final List<Map<String, dynamic>> _messages = [];
  final _chatCtl = TextEditingController();
  bool _sendingMsg = false;
  String _chatCursor = '';

  String get _base => '/api/v1/me/live/${widget.sessionId}';

  @override
  void initState() {
    super.initState();
    _title = widget.title;
    _pollState();
    _stateTimer = Timer.periodic(const Duration(seconds: 3), (_) => _pollState());
    _qaTimer = Timer.periodic(const Duration(seconds: 4), (_) => _pollQuestions());
    if (!widget.isHost) {
      _hbTimer = Timer.periodic(const Duration(seconds: 20), (_) => _heartbeat());
      _heartbeat();
    }
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _status == 'upcoming') setState(() {}); // refresh countdown
    });
    _pollQuestions();
    _chatTimer = Timer.periodic(const Duration(seconds: 4), (_) => _pollChat());
    _pollChat();
  }

  @override
  void dispose() {
    _stateTimer?.cancel();
    _qaTimer?.cancel();
    _hbTimer?.cancel();
    _tick?.cancel();
    _chatTimer?.cancel();
    _qaCtl.dispose();
    _chatCtl.dispose();
    super.dispose();
  }

  Future<void> _pollState() async {
    try {
      final d = ApiClient.decode(await widget.auth.apiGet('$_base/state'));
      if (!mounted) return;
      setState(() {
        _status = d['status']?.toString() ?? _status;
        _title = (d['title']?.toString().isNotEmpty ?? false) ? d['title'].toString() : _title;
        _course = d['course']?.toString() ?? _course;
        _viewers = (d['viewers'] as num?)?.toInt() ?? _viewers;
        _qaOn = d['qa_enabled'] == true;
        _startImage = d['start_image']?.toString() ?? '';
        _endImage = d['end_image']?.toString() ?? '';
        final sa = DateTime.tryParse(d['starts_at']?.toString() ?? '');
        _startsAt = sa?.toLocal();
        if (sa != null) _startEpochMs = sa.toUtc().millisecondsSinceEpoch;
        // Normalize to the SERVER clock so every viewer sees the same second even
        // if their device clock/timezone is wrong (skew = server_now - device_now).
        final sn = DateTime.tryParse(d['server_now']?.toString() ?? '');
        if (sn != null) _skewMs = sn.toUtc().millisecondsSinceEpoch - DateTime.now().millisecondsSinceEpoch;
        final p = d['playlist_url']?.toString();
        if (p != null && p.isNotEmpty) _playlistUrl = p.startsWith('http') ? p : '${Config.apiBase}$p';
        _loaded = true;
      });
    } on ApiException catch (e) {
      if (mounted && !_loaded) setState(() => _fatal = e.status == 403 ? 'You are not enrolled in this class.' : 'Could not load this session.');
    } catch (_) {/* transient */}
  }

  Future<void> _heartbeat() async {
    try {
      await widget.auth.apiPost('$_base/heartbeat', {});
    } catch (_) {}
  }

  Future<void> _pollQuestions() async {
    if (!_qaOn) return;
    try {
      final d = ApiClient.decode(await widget.auth.apiGet('$_base/questions'));
      final qs = ((d['questions'] as List?) ?? []).map((e) => (e as Map).cast<String, dynamic>()).toList();
      if (mounted) setState(() => _questions..clear()..addAll(qs));
    } catch (_) {}
  }

  Future<void> _sendQuestion() async {
    final text = _qaCtl.text.trim();
    if (text.isEmpty || _sendingQa) return;
    setState(() => _sendingQa = true);
    try {
      await widget.auth.apiPost('$_base/questions', {'body': text});
      _qaCtl.clear();
      await _pollQuestions();
    } catch (_) {} finally {
      if (mounted) setState(() => _sendingQa = false);
    }
  }

  // Poll the host's broadcast messages (from_staff) shown to every viewer.
  Future<void> _pollChat() async {
    try {
      final url = _chatCursor.isEmpty ? '$_base/chat' : '$_base/chat?after=${Uri.encodeQueryComponent(_chatCursor)}';
      final d = ApiClient.decode(await widget.auth.apiGet(url));
      final all = ((d['messages'] as List?) ?? []).map((e) => (e as Map).cast<String, dynamic>()).toList();
      if (all.isEmpty) return;
      if (!mounted) return;
      setState(() {
        for (final m in all) {
          if (m['from_staff'] == true && !_messages.any((x) => x['id'] == m['id'])) _messages.add(m);
        }
        final lastAt = all.last['at']?.toString() ?? ''; // advance past all we've seen
        if (lastAt.isNotEmpty) _chatCursor = lastAt;
      });
    } catch (_) {}
  }

  // Host: broadcast a message to all viewers.
  Future<void> _sendBroadcast() async {
    final text = _chatCtl.text.trim();
    if (text.isEmpty || _sendingMsg) return;
    setState(() => _sendingMsg = true);
    try {
      await widget.auth.apiPost('$_base/chat', {'body': text});
      _chatCtl.clear();
      await _pollChat();
    } catch (_) {} finally {
      if (mounted) setState(() => _sendingMsg = false);
    }
  }

  // Host: answer a specific question (delivered to the student who asked).
  Future<void> _answer(Map<String, dynamic> q) async {
    final ctl = TextEditingController(text: q['answer']?.toString() ?? '');
    final send = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _panel,
        title: Text('Answer', style: GoogleFonts.inter(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
        content: SizedBox(
          width: 560,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${q['name'] ?? 'Student'}: ${q['body'] ?? ''}', style: GoogleFonts.inter(color: Colors.white60, fontSize: 13)),
            const SizedBox(height: 12),
            TextField(
              controller: ctl,
              autofocus: true,
              minLines: 6,
              maxLines: 14,
              keyboardType: TextInputType.multiline,
              style: GoogleFonts.inter(color: Colors.white, fontSize: 14, height: 1.35),
              decoration: InputDecoration(
                hintText: 'Type your answer…',
                hintStyle: GoogleFonts.inter(color: Colors.white38, fontSize: 14),
                filled: true,
                fillColor: Colors.white.withOpacity(0.06),
                contentPadding: const EdgeInsets.all(14),
                border: OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide.none),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: GoogleFonts.inter(color: Colors.white54))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Send', style: GoogleFonts.inter(color: _orange, fontWeight: FontWeight.w700))),
        ],
      ),
    );
    if (send == true && ctl.text.trim().isNotEmpty) {
      try {
        await widget.auth.apiPost('$_base/questions/${q['id']}/answer', {'body': ctl.text.trim()});
        await _pollQuestions();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final sideBySide = widget.isHost || kIsWeb || w >= 600; // host: panel is the point
    final panelW = w < 900 ? (w * 0.36).clamp(260.0, 340.0) : 380.0;
    final showPanel = _qaOn || widget.isHost;
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: _fatal != null
            ? Center(child: Text(_fatal!, style: GoogleFonts.inter(color: Colors.white70)))
            : (sideBySide && showPanel)
                ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(child: Column(children: [_header(), Expanded(child: Center(child: _stage()))])),
                    Container(width: panelW, decoration: const BoxDecoration(border: Border(left: BorderSide(color: Color(0xFF222228)))), child: _qaPanel()),
                  ])
                : Column(children: [_header(), _stage(), if (showPanel) Expanded(child: _qaPanel())]),
      ),
    );
  }

  // ---- Header --------------------------------------------------------------
  Widget _header() {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 6, 12, 10),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF222228)))),
      child: Row(children: [
        IconButton(icon: const Icon(CupertinoIcons.chevron_back, color: Colors.white, size: 24), onPressed: () => Navigator.of(context).maybePop()),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Flexible(child: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(color: Colors.white, fontSize: 15.5, fontWeight: FontWeight.w700))),
              if (widget.isHost) ...[
                const SizedBox(width: 8),
                Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2), decoration: BoxDecoration(color: _orange.withOpacity(0.2), borderRadius: BorderRadius.zero, border: Border.all(color: _orange.withOpacity(0.5))), child: Text('MENTOR', style: GoogleFonts.inter(color: _orange, fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 0.5))),
              ],
            ]),
            if (_course.isNotEmpty) Text(_course, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(color: Colors.white54, fontSize: 12)),
          ]),
        ),
        if (_status == 'live') ...[
          _statusPill('● LIVE', _orange),
          const SizedBox(width: 8),
          Row(children: [
            const Icon(CupertinoIcons.eye_fill, size: 14, color: Colors.white60),
            const SizedBox(width: 4),
            Text(_fmtCount(_viewers), style: GoogleFonts.inter(color: Colors.white70, fontSize: 12.5, fontWeight: FontWeight.w600)),
          ]),
        ] else if (_status == 'ended')
          _statusPill('ENDED', Colors.white24)
        else
          _statusPill('STARTING SOON', const Color(0xFF3A86FF)),
      ]),
    );
  }

  Widget _statusPill(String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: c.withOpacity(0.18), borderRadius: BorderRadius.zero, border: Border.all(color: c.withOpacity(0.5))),
        child: Text(text, style: GoogleFonts.inter(color: c == Colors.white24 ? Colors.white60 : c, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.4)),
      );

  // ---- Stage ---------------------------------------------------------------
  // A 16:9 image (data URI or URL) that fills the stage — the admin's start/end
  // banners shown in place of the video before and after the class. Cached by
  // src (and gapless) so the lobby's 1-second countdown rebuild never re-decodes
  // the image — that was the flicker behind the countdown.
  Widget _imageCover(String src) => _coverCache.putIfAbsent(src, () => src.startsWith('data:')
      ? Image.memory(base64Decode(src.substring(src.indexOf(',') + 1)), fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, __, ___) => Container(color: Colors.black))
      : Image.network(src, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, __, ___) => Container(color: Colors.black)));

  Widget _stage() {
    // The host watches the live video too (when it's playing); otherwise they
    // see the host status panel (lobby / preparing / ended / queue summary).
    if (widget.isHost && !(_status == 'live' && _playlistUrl != null)) return _hostPanel();
    if (_status == 'live' && _playlistUrl != null) {
      return LivePlayer(key: ValueKey(_playlistUrl), playlistUrl: _playlistUrl!, watermark: widget.watermark, authToken: widget.auth.token, startEpochMs: _startEpochMs, skewMs: _skewMs, title: _title, course: _course);
    }
    if (_status == 'ended') {
      return _endImage.isNotEmpty
          ? AspectRatio(aspectRatio: 16 / 9, child: _imageCover(_endImage))
          : _placeholder(CupertinoIcons.checkmark_seal_fill, 'Session ended', 'This live session has finished.');
    }
    if (_status == 'preparing') return _preparing();
    return _lobby();
  }

  Widget _hostPanel() {
    final statusText = _status == 'live' ? 'LIVE NOW' : (_status == 'ended' ? 'ENDED' : (_status == 'preparing' ? 'PREPARING' : 'STARTING SOON'));
    final waiting = _questions.where((q) => q['answered'] != true).length;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        color: Colors.black,
        padding: const EdgeInsets.all(20),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(CupertinoIcons.dot_radiowaves_left_right, size: 48, color: _orange),
            const SizedBox(height: 14),
            Text(_title, textAlign: TextAlign.center, style: GoogleFonts.inter(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('$statusText · ${_fmtCount(_viewers)} watching', style: GoogleFonts.inter(color: Colors.white60, fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: _orange.withOpacity(waiting > 0 ? 0.18 : 0.06), borderRadius: BorderRadius.zero),
              child: Text(waiting > 0 ? '$waiting question${waiting == 1 ? '' : 's'} waiting → answer them in the panel' : 'No questions waiting. New questions appear in the panel.',
                  textAlign: TextAlign.center, style: GoogleFonts.inter(color: waiting > 0 ? _orange : Colors.white60, fontSize: 12.5, fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _lobby() {
    final remain = _startsAt == null ? null : _startsAt!.difference(DateTime.now());
    final countdown = remain == null || remain.isNegative ? 'Starting…' : _fmtCountdown(remain);
    final hasImg = _startImage.isNotEmpty;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(fit: StackFit.expand, children: [
        Container(color: Colors.black),
        // Start image in place of the video; the countdown stays on top.
        if (hasImg) _imageCover(_startImage),
        if (hasImg) Container(color: Colors.black.withOpacity(0.45)), // scrim for legibility
        Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (!hasImg) ...[
              const Icon(CupertinoIcons.videocam_circle_fill, size: 56, color: _orange),
              const SizedBox(height: 14),
            ],
            Text(_title, textAlign: TextAlign.center, style: GoogleFonts.inter(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('The class is about to begin', style: GoogleFonts.inter(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 18),
            Text(countdown, style: GoogleFonts.inter(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: 1)),
          ]),
        ),
      ]),
    );
  }

  Widget _preparing() => AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          color: Colors.black,
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const CupertinoActivityIndicator(color: Colors.white, radius: 16),
              const SizedBox(height: 16),
              Text(_title, textAlign: TextAlign.center, style: GoogleFonts.inter(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text('The live class is starting…', style: GoogleFonts.inter(color: Colors.white54, fontSize: 13)),
            ]),
          ),
        ),
      );

  Widget _placeholder(IconData icon, String title, String sub) => AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          color: Colors.black,
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 52, color: Colors.white38),
              const SizedBox(height: 12),
              Text(title, style: GoogleFonts.inter(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(sub, style: GoogleFonts.inter(color: Colors.white54, fontSize: 13)),
            ]),
          ),
        ),
      );

  // ---- Q&A panel (the only channel) ----------------------------------------
  Widget _qaPanel() {
    return Container(color: _panel, child: widget.isHost ? _hostQueue() : _studentQa());
  }

  // Mentor broadcasts shown to everyone in the room (newest at the bottom).
  Widget _mentorMessages() {
    if (_messages.isEmpty) return const SizedBox.shrink();
    return Container(
      constraints: const BoxConstraints(maxHeight: 150),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF222228)))),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        reverse: true,
        itemCount: _messages.length,
        itemBuilder: (_, i) {
          final m = _messages[_messages.length - 1 - i];
          return Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(CupertinoIcons.dot_radiowaves_left_right, size: 13, color: _orange),
              const SizedBox(width: 6),
              Expanded(
                child: RichText(text: TextSpan(children: [
                  TextSpan(text: '${(m['name']?.toString().isNotEmpty ?? false) ? m['name'] : 'Mentor'}  ', style: GoogleFonts.inter(color: _orange, fontSize: 11.5, fontWeight: FontWeight.w800)),
                  TextSpan(text: m['body']?.toString() ?? '', style: GoogleFonts.inter(color: Colors.white.withOpacity(0.92), fontSize: 12.5, height: 1.3)),
                ])),
              ),
            ]),
          );
        },
      ),
    );
  }

  // Student: ask the host; see your questions + the host's answers.
  Widget _studentQa() {
    final myId = widget.auth.user?.id ?? '';
    return Column(children: [
      _panelHeader('Ask Mentor', 'Ask your mentor — only your mentor sees your question.'),
      _mentorMessages(),
      Expanded(
        child: _questions.isEmpty
            ? Center(child: Text('No questions yet — ask away 👋', style: GoogleFonts.inter(color: Colors.white38, fontSize: 13)))
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                itemCount: _questions.length,
                itemBuilder: (_, i) {
                  final q = _questions[i];
                  final answered = q['answered'] == true;
                  final mine = (q['user_id']?.toString() ?? '') == myId;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(11),
                    decoration: BoxDecoration(color: Colors.white.withOpacity(0.04), borderRadius: BorderRadius.zero, border: Border.all(color: Colors.white12)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(mine ? 'You asked' : (q['name']?.toString() ?? 'Question'), style: GoogleFonts.inter(color: const Color(0xFF8AB4F8), fontSize: 11.5, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(q['body']?.toString() ?? '', style: GoogleFonts.inter(color: Colors.white.withOpacity(0.92), fontSize: 13, height: 1.25)),
                      const SizedBox(height: 8),
                      if (answered) ...[
                        Container(width: double.infinity, padding: const EdgeInsets.all(9), decoration: BoxDecoration(color: _orange.withOpacity(0.10), borderRadius: BorderRadius.zero), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Mentor answered', style: GoogleFonts.inter(color: _orange, fontSize: 11, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text(q['answer']?.toString() ?? '', style: GoogleFonts.inter(color: Colors.white.withOpacity(0.92), fontSize: 13, height: 1.25)),
                        ])),
                      ] else
                        Text('Awaiting answer…', style: GoogleFonts.inter(color: Colors.white38, fontSize: 11.5, fontStyle: FontStyle.italic)),
                    ]),
                  );
                },
              ),
      ),
      _composer(_qaCtl, 'Ask your mentor a question…', _sendQuestion, _sendingQa),
    ]);
  }

  // Host: the queue — unanswered first; answer each one (goes to the asker).
  Widget _hostQueue() {
    final waiting = _questions.where((q) => q['answered'] != true).length;
    return Column(children: [
      _panelHeader('Questions', waiting > 0 ? '$waiting waiting to be answered' : 'All caught up'),
      _mentorMessages(),
      Expanded(
        child: _questions.isEmpty
            ? Center(child: Text('No questions yet.', style: GoogleFonts.inter(color: Colors.white38, fontSize: 13)))
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                itemCount: _questions.length,
                itemBuilder: (_, i) {
                  final q = _questions[i];
                  final answered = q['answered'] == true;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(11),
                    decoration: BoxDecoration(
                      color: answered ? Colors.white.withOpacity(0.03) : _orange.withOpacity(0.07),
                      borderRadius: BorderRadius.zero,
                      border: Border.all(color: answered ? Colors.white10 : _orange.withOpacity(0.35)),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text(q['name']?.toString().isNotEmpty == true ? q['name'].toString() : 'Student', style: GoogleFonts.inter(color: const Color(0xFF8AB4F8), fontSize: 11.5, fontWeight: FontWeight.w700))),
                        if (answered) Text('Answered ✓', style: GoogleFonts.inter(color: const Color(0xFF34C759), fontSize: 10.5, fontWeight: FontWeight.w700)),
                      ]),
                      const SizedBox(height: 2),
                      Text(q['body']?.toString() ?? '', style: GoogleFonts.inter(color: Colors.white.withOpacity(0.92), fontSize: 13, height: 1.25)),
                      const SizedBox(height: 8),
                      if (answered)
                        Text('You: ${q['answer'] ?? ''}', style: GoogleFonts.inter(color: Colors.white54, fontSize: 12, height: 1.25))
                      else
                        Align(
                          alignment: Alignment.centerRight,
                          child: GestureDetector(
                            onTap: () => _answer(q),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                              decoration: BoxDecoration(color: _orange, borderRadius: BorderRadius.zero),
                              child: Text('Answer', style: GoogleFonts.inter(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700)),
                            ),
                          ),
                        ),
                      if (answered)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: GestureDetector(onTap: () => _answer(q), child: Text('Edit answer', style: GoogleFonts.inter(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w600))),
                        ),
                    ]),
                  );
                },
              ),
      ),
      _composer(_chatCtl, 'Message all viewers…', _sendBroadcast, _sendingMsg),
    ]);
  }

  Widget _panelHeader(String title, String sub) => Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF222228)))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: GoogleFonts.inter(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
          const SizedBox(height: 1),
          Text(sub, style: GoogleFonts.inter(color: Colors.white38, fontSize: 11)),
        ]),
      );

  Widget _composer(TextEditingController ctl, String hint, VoidCallback onSend, bool busy) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFF222228)))),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: ctl,
            minLines: 1,
            maxLines: 3,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => onSend(),
            style: GoogleFonts.inter(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: GoogleFonts.inter(color: Colors.white38, fontSize: 13),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              filled: true,
              fillColor: Colors.white.withOpacity(0.06),
              border: OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide.none),
            ),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: busy ? null : onSend,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: const BoxDecoration(color: _orange, shape: BoxShape.circle),
            child: busy
                ? const SizedBox(width: 18, height: 18, child: CupertinoActivityIndicator(color: Colors.white, radius: 8))
                : const Icon(CupertinoIcons.arrow_up, color: Colors.white, size: 18),
          ),
        ),
      ]),
    );
  }

  static String _fmtCount(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';

  static String _fmtCountdown(Duration d) {
    final h = d.inHours, m = d.inMinutes.remainder(60), s = d.inSeconds.remainder(60);
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }
}
