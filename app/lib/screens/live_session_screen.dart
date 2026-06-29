import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart' hide Config;

import '../config.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../widgets/live_player.dart';

/// The "live room" for a simulated-live session: a recorded video streamed as if
/// it were live, with a pre-start lobby + countdown, a real (polled) chat, a Q&A
/// panel, and a (real + simulated) viewer count. The student never sees a
/// scrubber or a "recorded" hint — it looks like a genuine live class.
class LiveSessionScreen extends StatefulWidget {
  const LiveSessionScreen({super.key, required this.auth, required this.sessionId, required this.watermark, this.title = 'Live Class'});
  final AuthService auth;
  final String sessionId;
  final String watermark;
  final String title;

  @override
  State<LiveSessionScreen> createState() => _LiveSessionScreenState();
}

class _LiveSessionScreenState extends State<LiveSessionScreen> {
  static const _orange = Color(0xFFFF4F2B);
  static const _bg = Color(0xFF0B0B0D);
  static const _panel = Color(0xFF15151A);

  Timer? _stateTimer, _chatTimer, _qaTimer, _hbTimer, _tick;

  // Server state.
  String _status = 'upcoming'; // upcoming | live | ended
  String _title = '';
  String _course = '';
  int _viewers = 0;
  bool _chatOn = true, _qaOn = true;
  String? _playlistUrl; // absolute, set once live
  DateTime? _startsAt;
  bool _loaded = false;
  String? _fatal;

  // Chat.
  final List<Map<String, dynamic>> _messages = [];
  final Set<String> _msgIds = {};
  String? _chatCursor;
  final _chatCtl = TextEditingController();
  final _chatScroll = ScrollController();
  bool _sendingChat = false;

  // Q&A.
  final List<Map<String, dynamic>> _questions = [];
  final _qaCtl = TextEditingController();
  bool _sendingQa = false;

  String get _base => '/api/v1/me/live/${widget.sessionId}';

  @override
  void initState() {
    super.initState();
    _title = widget.title;
    _pollState();
    _stateTimer = Timer.periodic(const Duration(seconds: 3), (_) => _pollState());
    _chatTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) => _pollChat());
    _qaTimer = Timer.periodic(const Duration(seconds: 6), (_) => _pollQuestions());
    _hbTimer = Timer.periodic(const Duration(seconds: 20), (_) => _heartbeat());
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _status == 'upcoming') setState(() {}); // refresh countdown
    });
    _heartbeat();
    _pollChat();
    _pollQuestions();
  }

  @override
  void dispose() {
    _stateTimer?.cancel();
    _chatTimer?.cancel();
    _qaTimer?.cancel();
    _hbTimer?.cancel();
    _tick?.cancel();
    _chatCtl.dispose();
    _qaCtl.dispose();
    _chatScroll.dispose();
    super.dispose();
  }

  Future<void> _pollState() async {
    try {
      final r = await widget.auth.apiGet('$_base/state');
      final d = ApiClient.decode(r);
      if (!mounted) return;
      setState(() {
        _status = d['status']?.toString() ?? _status;
        _title = (d['title']?.toString().isNotEmpty ?? false) ? d['title'].toString() : _title;
        _course = d['course']?.toString() ?? _course;
        _viewers = (d['viewers'] as num?)?.toInt() ?? _viewers;
        _chatOn = d['chat_enabled'] == true;
        _qaOn = d['qa_enabled'] == true;
        _startsAt = DateTime.tryParse(d['starts_at']?.toString() ?? '')?.toLocal();
        final p = d['playlist_url']?.toString();
        if (p != null && p.isNotEmpty) _playlistUrl = '${Config.apiBase}$p';
        _loaded = true;
      });
    } on ApiException catch (e) {
      if (mounted && !_loaded) setState(() => _fatal = e.status == 403 ? 'You are not enrolled in this class.' : 'Could not load this session.');
    } catch (_) {/* transient network — keep last state */}
  }

  Future<void> _heartbeat() async {
    try {
      await widget.auth.apiPost('$_base/heartbeat', {});
    } catch (_) {}
  }

  Future<void> _pollChat() async {
    if (!_chatOn) return;
    try {
      final path = _chatCursor == null ? '$_base/chat' : '$_base/chat?after=${Uri.encodeQueryComponent(_chatCursor!)}';
      final d = ApiClient.decode(await widget.auth.apiGet(path));
      final msgs = (d['messages'] as List?) ?? [];
      if (msgs.isEmpty || !mounted) return;
      var added = false;
      for (final m in msgs) {
        final mm = (m as Map).cast<String, dynamic>();
        final id = mm['id']?.toString() ?? '';
        if (id.isEmpty || _msgIds.contains(id)) continue;
        _msgIds.add(id);
        _messages.add(mm);
        _chatCursor = mm['at']?.toString() ?? _chatCursor;
        added = true;
      }
      if (added) {
        setState(() {});
        _scrollChatToEnd();
      }
    } catch (_) {}
  }

  Future<void> _sendChat() async {
    final text = _chatCtl.text.trim();
    if (text.isEmpty || _sendingChat) return;
    setState(() => _sendingChat = true);
    try {
      await widget.auth.apiPost('$_base/chat', {'body': text});
      _chatCtl.clear();
      await _pollChat();
    } catch (_) {} finally {
      if (mounted) setState(() => _sendingChat = false);
    }
  }

  Future<void> _pollQuestions() async {
    if (!_qaOn) return;
    try {
      final d = ApiClient.decode(await widget.auth.apiGet('$_base/questions'));
      final qs = ((d['questions'] as List?) ?? []).map((e) => (e as Map).cast<String, dynamic>()).toList();
      if (mounted) setState(() => _questions
        ..clear()
        ..addAll(qs));
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

  void _scrollChatToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients) _chatScroll.jumpTo(_chatScroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 900;
    final hasPanel = _chatOn || _qaOn;
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: _fatal != null
            ? Center(child: Text(_fatal!, style: GoogleFonts.poppins(color: Colors.white70)))
            : wide
                ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(child: Column(children: [_header(), Expanded(child: Center(child: _stage()))])),
                    if (hasPanel) SizedBox(width: 350, child: _sidePanel()),
                  ])
                : Column(children: [
                    _header(),
                    _stage(),
                    if (hasPanel) Expanded(child: _sidePanel()),
                  ]),
      ),
    );
  }

  // ---- Header --------------------------------------------------------------
  Widget _header() {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 6, 12, 10),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF222228)))),
      child: Row(children: [
        IconButton(
          icon: const Icon(CupertinoIcons.chevron_back, color: Colors.white, size: 24),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.poppins(color: Colors.white, fontSize: 15.5, fontWeight: FontWeight.w700)),
            if (_course.isNotEmpty)
              Text(_course, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.poppins(color: Colors.white54, fontSize: 12)),
          ]),
        ),
        if (_status == 'live') ...[
          _statusPill('● LIVE', _orange),
          const SizedBox(width: 8),
          Row(children: [
            const Icon(CupertinoIcons.eye_fill, size: 14, color: Colors.white60),
            const SizedBox(width: 4),
            Text(_fmtCount(_viewers), style: GoogleFonts.poppins(color: Colors.white70, fontSize: 12.5, fontWeight: FontWeight.w600)),
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
        decoration: BoxDecoration(color: c.withOpacity(0.18), borderRadius: BorderRadius.circular(6), border: Border.all(color: c.withOpacity(0.5))),
        child: Text(text, style: GoogleFonts.poppins(color: c == Colors.white24 ? Colors.white60 : c, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.4)),
      );

  // ---- Stage (player / lobby / ended) --------------------------------------
  Widget _stage() {
    if (_status == 'live' && _playlistUrl != null) {
      return LivePlayer(key: ValueKey(_playlistUrl), playlistUrl: _playlistUrl!, watermark: widget.watermark, authToken: widget.auth.token);
    }
    if (_status == 'ended') {
      return _placeholder(CupertinoIcons.checkmark_seal_fill, 'This live class has ended', 'Thanks for joining.');
    }
    return _lobby();
  }

  Widget _lobby() {
    final remain = _startsAt == null ? null : _startsAt!.difference(DateTime.now());
    final countdown = remain == null || remain.isNegative ? 'Starting…' : _fmtCountdown(remain);
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        color: Colors.black,
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(CupertinoIcons.videocam_circle_fill, size: 56, color: _orange),
            const SizedBox(height: 14),
            Text(_title, textAlign: TextAlign.center, style: GoogleFonts.poppins(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('The class is about to begin', style: GoogleFonts.poppins(color: Colors.white54, fontSize: 13)),
            const SizedBox(height: 18),
            Text(countdown, style: GoogleFonts.poppins(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: 1)),
          ]),
        ),
      ),
    );
  }

  Widget _placeholder(IconData icon, String title, String sub) => AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          color: Colors.black,
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 52, color: Colors.white38),
              const SizedBox(height: 12),
              Text(title, style: GoogleFonts.poppins(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(sub, style: GoogleFonts.poppins(color: Colors.white54, fontSize: 13)),
            ]),
          ),
        ),
      );

  // ---- Side panel (Chat + Q&A tabs) ----------------------------------------
  Widget _sidePanel() {
    final tabs = <Tab>[];
    final views = <Widget>[];
    if (_chatOn) {
      tabs.add(const Tab(text: 'Chat'));
      views.add(_chatTab());
    }
    if (_qaOn) {
      tabs.add(const Tab(text: 'Q&A'));
      views.add(_qaTab());
    }
    if (tabs.length == 1) {
      return Container(color: _panel, child: views.first);
    }
    return DefaultTabController(
      length: tabs.length,
      child: Container(
        color: _panel,
        child: Column(children: [
          TabBar(tabs: tabs, indicatorColor: _orange, labelColor: Colors.white, unselectedLabelColor: Colors.white54, labelStyle: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 13)),
          Expanded(child: TabBarView(children: views)),
        ]),
      ),
    );
  }

  Widget _chatTab() {
    final myId = widget.auth.user?.id ?? '';
    return Column(children: [
      Expanded(
        child: _messages.isEmpty
            ? Center(child: Text('Say hello 👋', style: GoogleFonts.poppins(color: Colors.white38, fontSize: 13)))
            : ListView.builder(
                controller: _chatScroll,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                itemCount: _messages.length,
                itemBuilder: (_, i) {
                  final m = _messages[i];
                  final mine = (m['user_id']?.toString() ?? '') == myId;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 9),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(mine ? 'You' : (m['name']?.toString().isNotEmpty == true ? m['name'].toString() : 'Student'),
                          style: GoogleFonts.poppins(color: mine ? _orange : const Color(0xFF8AB4F8), fontSize: 11.5, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 1),
                      Text(m['body']?.toString() ?? '', style: GoogleFonts.poppins(color: Colors.white.withOpacity(0.92), fontSize: 13, height: 1.25)),
                    ]),
                  );
                },
              ),
      ),
      _composer(_chatCtl, 'Message…', _sendChat, _sendingChat),
    ]);
  }

  Widget _qaTab() {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Text('Ask the host a question. Questions are visible to everyone.', style: GoogleFonts.poppins(color: Colors.white38, fontSize: 11.5)),
      ),
      Expanded(
        child: _questions.isEmpty
            ? Center(child: Text('No questions yet.', style: GoogleFonts.poppins(color: Colors.white38, fontSize: 13)))
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                itemCount: _questions.length,
                itemBuilder: (_, i) {
                  final q = _questions[i];
                  final answered = q['answered'] == true;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: Colors.white.withOpacity(0.04), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.white12)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text(q['name']?.toString().isNotEmpty == true ? q['name'].toString() : 'Student', style: GoogleFonts.poppins(color: const Color(0xFF8AB4F8), fontSize: 11.5, fontWeight: FontWeight.w700))),
                        if (answered)
                          Text('Answered', style: GoogleFonts.poppins(color: const Color(0xFF34C759), fontSize: 10.5, fontWeight: FontWeight.w700)),
                      ]),
                      const SizedBox(height: 2),
                      Text(q['body']?.toString() ?? '', style: GoogleFonts.poppins(color: Colors.white.withOpacity(0.92), fontSize: 13, height: 1.25)),
                    ]),
                  );
                },
              ),
      ),
      _composer(_qaCtl, 'Ask a question…', _sendQuestion, _sendingQa),
    ]);
  }

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
            style: GoogleFonts.poppins(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: GoogleFonts.poppins(color: Colors.white38, fontSize: 13),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              filled: true,
              fillColor: Colors.white.withOpacity(0.06),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
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
