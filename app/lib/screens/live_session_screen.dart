import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart' hide Config;

import '../config.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/web_download_stub.dart' if (dart.library.html) '../services/web_download_web.dart';
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
  // Host room-controls, mirrored from /state so every viewer reacts together.
  bool _reactionsOn = true;
  bool _paused = false;
  bool _blank = false;
  bool _hostMuted = false;
  String _banner = '';
  bool _sendingCtl = false;
  int _elapsed = 0; // seconds played (host progress readout)
  int _duration = 0; // total recording length (seconds)
  int _reloadSeq = 0; // bumped when the host seeks → re-init the player
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

  // Floating reactions (👍👏❤️😂😮🎉🚀👌). Tapping floats it locally and posts
  // it; the server batches the room's reactions onto the /state poll everyone
  // already makes, so incoming reactions float too with no extra requests.
  static const _reactEmojis = ['👍', '👏', '❤️', '😂', '😮', '🎉', '🚀', '👌'];
  final List<_FloatSpec> _floats = [];
  int _floatId = 0;
  int _reactSeq = 0;
  final _rand = math.Random();

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
        _reactionsOn = d['reactions_enabled'] != false;
        _paused = d['paused'] == true;
        _blank = d['blank'] == true;
        _hostMuted = d['muted'] == true;
        _banner = d['banner']?.toString() ?? '';
        _elapsed = (d['elapsed'] as num?)?.toInt() ?? _elapsed;
        _duration = (d['duration'] as num?)?.toInt() ?? _duration;
        _reloadSeq = (d['reload_seq'] as num?)?.toInt() ?? _reloadSeq;
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
      _absorbReactions(d); // float the room's reactions from this poll
    } on ApiException catch (e) {
      if (mounted && !_loaded) setState(() => _fatal = e.status == 403 ? 'You are not enrolled in this class.' : 'Could not load this session.');
    } catch (_) {/* transient */}
  }

  // Send a reaction: float it immediately for snappy feedback, then post it so
  // it reaches the rest of the room on their next state poll.
  Future<void> _react(String emoji) async {
    _spawnFloat(emoji);
    try {
      await widget.auth.apiPost('$_base/react', {'emoji': emoji});
    } catch (_) {}
  }

  // Float the reaction batch the server folded onto /state. seq guards against
  // floating the same batch twice across polls.
  void _absorbReactions(Map<String, dynamic> d) {
    final seq = (d['reactions_seq'] as num?)?.toInt() ?? 0;
    if (seq == 0 || seq == _reactSeq) return;
    _reactSeq = seq;
    final r = (d['reactions'] as Map?) ?? const {};
    r.forEach((k, v) {
      final n = ((v as num?)?.toInt() ?? 0).clamp(0, 6); // cap the burst per emoji
      for (var i = 0; i < n; i++) {
        Future.delayed(Duration(milliseconds: i * 200), () => _spawnFloat(k.toString()));
      }
    });
  }

  void _spawnFloat(String emoji) {
    if (!mounted) return;
    final id = _floatId++;
    setState(() {
      _floats.add(_FloatSpec(id, emoji, 0.12 + _rand.nextDouble() * 0.76));
      if (_floats.length > 28) _floats.removeAt(0); // bound the overlay
    });
  }

  void _removeFloat(int id) {
    if (!mounted) return;
    setState(() => _floats.removeWhere((f) => f.id == id));
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

  // Host: push a room control (pause/blank/mute/toggle/start/end/banner) then
  // refresh state so the panel reflects it immediately.
  Future<void> _control(Map<String, dynamic> body) async {
    if (_sendingCtl) return;
    setState(() => _sendingCtl = true);
    try {
      await widget.auth.apiPost('$_base/control', body);
      await _pollState();
    } catch (_) {} finally {
      if (mounted) setState(() => _sendingCtl = false);
    }
  }

  Future<void> _editBanner() async {
    final ctl = TextEditingController(text: _banner);
    final res = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _panel,
        title: Text('Banner over the video', style: GoogleFonts.inter(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLength: 200,
          minLines: 1,
          maxLines: 3,
          style: GoogleFonts.inter(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Shown to everyone over the video…',
            hintStyle: GoogleFonts.inter(color: Colors.white38, fontSize: 14),
            filled: true,
            fillColor: Colors.white.withOpacity(0.06),
            border: OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, ' '), child: Text('Clear', style: GoogleFonts.inter(color: Colors.white54))),
          TextButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: Text('Show', style: GoogleFonts.inter(color: _orange, fontWeight: FontWeight.w700))),
        ],
      ),
    );
    if (res == null) return;
    await _control({'banner': res == ' ' ? '' : res});
  }

  // The host's live-control bar: pause, black-out, mute-all, toggles, banner,
  // and start/end-now. Broadcast to every viewer via the session state.
  Widget _hostControls() {
    final liveNow = _status == 'live';
    // Each entry is one control tile; laid out as an even grid below.
    final tiles = <Widget>[
      _ctlChip(_paused ? 'Resume' : 'Pause', _paused ? CupertinoIcons.play_fill : CupertinoIcons.pause_fill, _paused,
          () => _confirmAct(_paused ? 'Resume the class for everyone?' : 'Pause the class for everyone?', () => _control({'paused': !_paused}))),
      _ctlChip('Black-out', CupertinoIcons.rectangle_fill, _blank,
          () => _confirmAct(_blank ? 'Remove the black-out?' : 'Black out the video for everyone?', () => _control({'blank': !_blank}))),
      _ctlChip('Mute all', _hostMuted ? CupertinoIcons.volume_off : CupertinoIcons.volume_up, _hostMuted,
          () => _confirmAct(_hostMuted ? 'Unmute for everyone?' : 'Mute audio for everyone?', () => _control({'muted': !_hostMuted}))),
      _ctlChip('Reactions', CupertinoIcons.hand_thumbsup, _reactionsOn,
          () => _confirmAct(_reactionsOn ? 'Turn reactions off?' : 'Turn reactions on?', () => _control({'reactions_enabled': !_reactionsOn}))),
      _ctlChip('Q&A', CupertinoIcons.chat_bubble_2, _qaOn,
          () => _confirmAct(_qaOn ? 'Turn Q&A off?' : 'Turn Q&A on?', () => _control({'qa_enabled': !_qaOn}))),
      _ctlChip('Banner', CupertinoIcons.textformat, _banner.isNotEmpty, _editBanner),
      _ctlChip('Switch video', CupertinoIcons.arrow_2_squarepath, false, _switchVideo),
      _ctlChip('Attendance', CupertinoIcons.person_2_fill, false, _showAttendance),
      if (!liveNow)
        _ctlChip('Start now', CupertinoIcons.play_circle, false,
            () => _confirmAct('Start the class now for everyone?', () => _control({'start_now': true})))
      else
        _ctlChip('End now', CupertinoIcons.stop_circle_fill, false,
            () => _confirmAct('End the class now for everyone?', () => _control({'end_now': true}))),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF222228)))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _hostProgress(),
        LayoutBuilder(builder: (ctx, cons) {
          const gap = 7.0;
          final cols = (cons.maxWidth / 118).floor().clamp(2, 4);
          final itemW = (cons.maxWidth - gap * (cols - 1)) / cols;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [for (final t in tiles) SizedBox(width: itemW, child: t)],
          );
        }),
      ]),
    );
  }

  // Confirm a broadcast action before it hits every viewer.
  Future<void> _confirmAct(String message, Future<void> Function() act) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _panel,
        content: Text(message, style: GoogleFonts.inter(color: Colors.white, fontSize: 14.5, height: 1.3)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: GoogleFonts.inter(color: Colors.white54))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Confirm', style: GoogleFonts.inter(color: _orange, fontWeight: FontWeight.w700))),
        ],
      ),
    );
    if (ok == true) await act();
  }

  // Host: jump the whole class to a position in the recording (seek for
  // everyone). Clamped to just short of the end so it doesn't trip "ended".
  void _seekTo(int seconds) {
    if (_duration <= 0) return;
    final t = seconds.clamp(0, _duration - 2 > 0 ? _duration - 2 : 0);
    _control({'seek_to': t});
  }

  // Host readout + SEEK: played / total / remaining, a tap-to-seek progress bar,
  // and ±10s / ±1m skips. Frozen at the pause point while paused.
  Widget _hostProgress() {
    if (_duration <= 0) return const SizedBox.shrink();
    final played = _elapsed.clamp(0, _duration);
    final remain = _duration - played;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('${_fmtHMS(played)} / ${_fmtHMS(_duration)}', style: GoogleFonts.inter(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w600)),
          const Spacer(),
          Text('${_fmtHMS(remain)} left', style: GoogleFonts.inter(color: _paused ? const Color(0xFFFFB020) : Colors.white54, fontSize: 11.5, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 6),
        LayoutBuilder(builder: (ctx, cons) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _seekTo(((d.localPosition.dx / cons.maxWidth).clamp(0.0, 1.0) * _duration).round()),
              child: SizedBox(
                height: 16,
                child: Center(child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(value: (played / _duration).clamp(0.0, 1.0), minHeight: 5, backgroundColor: Colors.white12, valueColor: const AlwaysStoppedAnimation(_orange)),
                )),
              ),
            )),
        const SizedBox(height: 8),
        Row(children: [
          _skipChip('-1m', () => _seekTo(played - 60)),
          const SizedBox(width: 6),
          _skipChip('-10s', () => _seekTo(played - 10)),
          const SizedBox(width: 6),
          _skipChip('+10s', () => _seekTo(played + 10)),
          const SizedBox(width: 6),
          _skipChip('+1m', () => _seekTo(played + 60)),
        ]),
      ]),
    );
  }

  Widget _skipChip(String label, VoidCallback onTap) => GestureDetector(
        onTap: _sendingCtl ? null : onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(color: Colors.white.withOpacity(0.06), border: Border.all(color: Colors.white24)),
          child: Text(label, style: GoogleFonts.inter(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w700)),
        ),
      );

  // Host: switch the class to a different recording. Everyone re-inits their
  // player (reload_seq) at the start of the chosen video.
  Future<void> _switchVideo() async {
    List<Map<String, dynamic>> vids = [];
    try {
      final d = ApiClient.decode(await widget.auth.apiGet('$_base/videos'));
      vids = ((d['videos'] as List?) ?? []).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (_) {}
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: _panel,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Switch video', style: GoogleFonts.inter(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 3),
            Text('Everyone jumps to the start of the chosen recording.', style: GoogleFonts.inter(color: Colors.white38, fontSize: 12)),
            const SizedBox(height: 12),
            if (vids.isEmpty)
              const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Center(child: Text('No ready videos to switch to.', style: TextStyle(color: Colors.white38, fontSize: 13))))
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: vids.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFF222228)),
                  itemBuilder: (_, i) {
                    final v = vids[i];
                    final dur = (v['duration_seconds'] as num?)?.toInt() ?? 0;
                    final title = v['title']?.toString() ?? '';
                    return InkWell(
                      onTap: () {
                        Navigator.pop(ctx);
                        _control({'switch_to': v['id']});
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        child: Row(children: [
                          const Icon(CupertinoIcons.play_rectangle_fill, size: 17, color: Colors.white54),
                          const SizedBox(width: 10),
                          Expanded(child: Text(title.isNotEmpty ? title : 'Untitled', maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(color: Colors.white, fontSize: 13.5))),
                          Text(_fmtHMS(dur), style: GoogleFonts.inter(color: Colors.white38, fontSize: 12)),
                        ]),
                      ),
                    );
                  },
                ),
              ),
          ]),
        ),
      ),
    );
  }

  // Host: who watched and for how long, with a CSV download (web).
  Future<void> _showAttendance() async {
    List<Map<String, dynamic>> rows = [];
    try {
      final d = ApiClient.decode(await widget.auth.apiGet('$_base/attendance'));
      rows = ((d['attendance'] as List?) ?? []).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (_) {}
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: _panel,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('Attendance · ${rows.length}', style: GoogleFonts.inter(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
              const Spacer(),
              GestureDetector(
                onTap: rows.isEmpty ? null : () => downloadText('attendance-${widget.sessionId}.csv', _attendanceCsv(rows)),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(color: rows.isEmpty ? Colors.white12 : _orange, borderRadius: BorderRadius.zero),
                  child: Text('Download CSV', style: GoogleFonts.inter(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700)),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            if (rows.isEmpty)
              const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Center(child: Text('No attendance recorded yet.', style: TextStyle(color: Colors.white38, fontSize: 13))))
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFF222228)),
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    final w = (r['watched_seconds'] as num?)?.toInt() ?? 0;
                    final name = r['name']?.toString() ?? '';
                    final who = name.isNotEmpty ? name : (r['email']?.toString().isNotEmpty ?? false ? r['email'].toString() : (r['phone']?.toString() ?? 'Student'));
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      child: Row(children: [
                        Expanded(child: Text(who, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(color: Colors.white, fontSize: 13))),
                        Text(_fmtHMS(w), style: GoogleFonts.inter(color: Colors.white60, fontSize: 12.5, fontWeight: FontWeight.w600)),
                      ]),
                    );
                  },
                ),
              ),
          ]),
        ),
      ),
    );
  }

  String _attendanceCsv(List<Map<String, dynamic>> rows) {
    String esc(Object? v) => '"${(v ?? '').toString().replaceAll('"', '""')}"';
    final b = StringBuffer('Name,Email,Phone,Login ID,First seen,Last seen,Watched (min)\n');
    for (final r in rows) {
      final w = (r['watched_seconds'] as num?)?.toInt() ?? 0;
      b.writeln([esc(r['name']), esc(r['email']), esc(r['phone']), esc(r['login_id']), esc(r['first_seen']), esc(r['last_seen']), (w / 60).toStringAsFixed(1)].join(','));
    }
    return b.toString();
  }

  Widget _ctlChip(String label, IconData icon, bool active, VoidCallback onTap) => GestureDetector(
        onTap: _sendingCtl ? null : onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          decoration: BoxDecoration(
            color: active ? _orange.withOpacity(0.9) : Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.zero,
            border: Border.all(color: active ? _orange : Colors.white24),
          ),
          child: Row(mainAxisSize: MainAxisSize.max, mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 14, color: active ? Colors.white : Colors.white70),
            const SizedBox(width: 5),
            Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(color: active ? Colors.white : Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w700))),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    // Desktop-style side panel when there's room OR the device is in landscape;
    // a phone in PORTRAIT stacks the video on top with the panel below, and
    // rotating it to landscape flips to the desktop side-by-side layout. Host is
    // always side-by-side — the panel (the question queue) is the whole point.
    final isLandscape = size.width >= size.height;
    final sideBySide = widget.isHost || size.width >= 720 || isLandscape;
    final panelW = size.width < 900 ? (size.width * 0.36).clamp(260.0, 340.0) : 380.0;
    final showPanel = _qaOn || widget.isHost;
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: _fatal != null
            ? Center(child: Text(_fatal!, style: GoogleFonts.inter(color: Colors.white70)))
            : (sideBySide && showPanel)
                ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(child: Column(children: [_header(), Expanded(child: Center(child: _stageArea()))])),
                    Container(width: panelW, decoration: const BoxDecoration(border: Border(left: BorderSide(color: Color(0xFF222228)))), child: _qaPanel()),
                  ])
                : Column(children: [_header(), _stageArea(), if (showPanel) Expanded(child: _qaPanel())]),
      ),
    );
  }

  // The video stage with the floating-reactions overlay on top. The host's
  // black-out / pause cover and pinned banner are drawn INSIDE the player
  // (LivePlayer) — as HTML on web, Flutter on mobile — because a Flutter widget
  // can't reliably paint over the web <video> element.
  Widget _stageArea() => Stack(alignment: Alignment.center, children: [
        _stage(),
        Positioned.fill(child: IgnorePointer(child: Stack(clipBehavior: Clip.hardEdge, children: [
          for (final f in _floats) _Floaty(key: ValueKey(f.id), emoji: f.emoji, startX: f.x, onDone: () => _removeFloat(f.id)),
        ]))),
      ]);

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
      return LivePlayer(key: ValueKey('$_playlistUrl|$_reloadSeq'), playlistUrl: _playlistUrl!, watermark: widget.watermark, authToken: widget.auth.token, startEpochMs: _startEpochMs, skewMs: _skewMs, title: _title, course: _course, hostMuted: _hostMuted || _blank || _paused, blank: _blank, paused: _paused, banner: _banner);
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
      _reactionBar(),
      _composer(_qaCtl, 'Ask your mentor a question…', _sendQuestion, _sendingQa),
    ]);
  }

  // Host: the queue — unanswered first; answer each one (goes to the asker).
  Widget _hostQueue() {
    final waiting = _questions.where((q) => q['answered'] != true).length;
    return Column(children: [
      _panelHeader('Questions', waiting > 0 ? '$waiting waiting to be answered' : 'All caught up'),
      _hostControls(),
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
      _reactionBar(),
      _composer(_chatCtl, 'Message all viewers…', _sendBroadcast, _sendingMsg),
    ]);
  }

  // Emoji reactions row at the bottom of the panel; a tap floats it over the
  // video and broadcasts it to the room. FittedBox guarantees it never overflows
  // a narrow side panel. Hidden when the host has turned reactions off.
  Widget _reactionBar() => !_reactionsOn
      ? const SizedBox.shrink()
      : Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFF222228)))),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.center,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (final e in _reactEmojis)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _react(e),
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2), child: Text(e, style: const TextStyle(fontSize: 23))),
              ),
          ]),
        ),
      );

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

  static String _fmtHMS(int s) {
    if (s < 0) s = 0;
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
  }

  static String _fmtCountdown(Duration d) {
    final h = d.inHours, m = d.inMinutes.remainder(60), s = d.inSeconds.remainder(60);
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }
}

// One in-flight floating reaction: a stable id, the emoji, and its horizontal
// start position (0..1 across the stage).
class _FloatSpec {
  const _FloatSpec(this.id, this.emoji, this.x);
  final int id;
  final String emoji;
  final double x;
}

// A single emoji that rises up the video, drifting and fading, then removes
// itself. Self-contained controller so many can run without parent rebuilds.
class _Floaty extends StatefulWidget {
  const _Floaty({super.key, required this.emoji, required this.startX, required this.onDone});
  final String emoji;
  final double startX;
  final VoidCallback onDone;

  @override
  State<_Floaty> createState() => _FloatyState();
}

class _FloatyState extends State<_Floaty> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    });
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final t = _c.value;
        final rise = Curves.easeOut.transform(t); // 0 → 1
        final y = 1.0 - 1.9 * rise; // bottom (1) → near top (−0.9)
        final drift = math.sin(t * math.pi * 3) * 0.05;
        final x = (widget.startX * 2 - 1 + drift).clamp(-1.0, 1.0);
        final opacity = t < 0.12 ? t / 0.12 : (t > 0.75 ? (1 - (t - 0.75) / 0.25) : 1.0);
        final scale = 0.6 + 0.55 * Curves.easeOutBack.transform((t * 2.2).clamp(0.0, 1.0));
        return Align(
          alignment: Alignment(x, y.clamp(-1.0, 1.0)),
          child: Opacity(
            opacity: opacity.clamp(0.0, 1.0),
            child: Transform.scale(
              scale: scale,
              child: Text(widget.emoji, style: const TextStyle(fontSize: 30, shadows: [Shadow(color: Colors.black54, blurRadius: 8)])),
            ),
          ),
        );
      },
    );
  }
}
