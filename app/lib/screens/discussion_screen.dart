import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import '../widgets/ui.dart';

/// Per-course doubts & discussion board. Students post doubts/comments;
/// instructors and peers reply. Used by both the student and instructor sides.
class DiscussionScreen extends StatefulWidget {
  const DiscussionScreen({super.key, required this.auth, required this.courseId, required this.title});
  final AuthService auth;
  final String courseId;
  final String title;

  @override
  State<DiscussionScreen> createState() => _DiscussionScreenState();
}

class _DiscussionScreenState extends State<DiscussionScreen> {
  List<dynamic> _posts = [];
  List<dynamic> _moduleDoubts = []; // per-module comments/doubts (staff view)
  bool _loading = true;
  bool _sending = false;
  String? _replyTo;
  String? _replyToName;
  String? _replyModuleId; // when set, the composer posts into a module thread
  String? _replyThreadUser; // whose private module thread we're answering into
  final _input = TextEditingController();

  bool get _isStaff {
    final r = widget.auth.user?.role;
    return r == 'instructor' || r == 'manager' || r == 'superadmin';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.auth.apiGet('/api/v1/courses/${widget.courseId}/discussion');
      _posts = (ApiClient.decode(r)['discussion'] as List?) ?? [];
    } catch (_) {}
    // Staff also see the doubts students raise inside each module.
    if (_isStaff) {
      try {
        final r = await widget.auth.apiGet('/api/v1/manage/courses/${widget.courseId}/comments');
        _moduleDoubts = (ApiClient.decode(r)['comments'] as List?) ?? [];
      } catch (_) {}
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _send() async {
    final body = _input.text.trim();
    if (body.isEmpty) return;
    setState(() => _sending = true);
    try {
      if (_replyModuleId != null) {
        await widget.auth.apiPost('/api/v1/modules/$_replyModuleId/comments', {
          'body': body,
          // Reply into the student's PRIVATE thread so only they (and staff) see it.
          if (_replyThreadUser != null) 'thread_user_id': _replyThreadUser,
        });
      } else {
        await widget.auth.apiPost('/api/v1/courses/${widget.courseId}/discussion', {
          'body': body,
          if (_replyTo != null) 'parent_id': _replyTo,
        });
      }
      _input.clear();
      _replyTo = null;
      _replyToName = null;
      _replyModuleId = null;
      _replyThreadUser = null;
      await _load();
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not post')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final w = MediaQuery.of(context).size.width;
    final hp = (w > 760 ? (w - 720) / 2 : 14.0).clamp(14, 400).toDouble();
    return Scaffold(
      appBar: AppBar(
        backgroundColor: p.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(icon: const Icon(CupertinoIcons.chevron_left), onPressed: () => Navigator.pop(context)),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Doubts & Discussion', style: AppleTheme.headline(context)),
          Text(widget.title, style: AppleTheme.footnote(context)),
        ]),
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CupertinoActivityIndicator())
                : (_posts.isEmpty && _moduleDoubts.isEmpty)
                    ? Center(child: Padding(padding: EdgeInsets.symmetric(horizontal: hp), child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(CupertinoIcons.chat_bubble_2_fill, size: 38, color: AppleColors.blue),
                        const SizedBox(height: 10),
                        Text('No posts yet', style: AppleTheme.headline(context)),
                        const SizedBox(height: 4),
                        Text('Ask a doubt or start the discussion below.', style: AppleTheme.footnote(context), textAlign: TextAlign.center),
                      ])))
                    : RefreshIndicator(
                        color: p.accent,
                        onRefresh: _load,
                        child: ListView(
                          padding: EdgeInsets.fromLTRB(hp, 12, hp, 16),
                          children: [
                            if (_moduleDoubts.isNotEmpty) ...[
                              SectionHeader('Module doubts & comments (${_moduleDoubts.length})'),
                              const SizedBox(height: 8),
                              ..._moduleDoubts.map((e) => _moduleDoubtCard(e as Map<String, dynamic>)),
                              const SizedBox(height: 18),
                              if (_posts.isNotEmpty) SectionHeader('Course discussion'),
                              const SizedBox(height: 8),
                            ],
                            ..._posts.map((e) => _postCard(e as Map<String, dynamic>)),
                          ],
                        ),
                      ),
          ),
          _composer(hp),
        ],
      ),
    );
  }

  Widget _postCard(Map<String, dynamic> post) {
    final replies = (post['replies'] as List?) ?? [];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppleCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _msgRow(post),
          if (replies.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.only(left: 12),
              decoration: BoxDecoration(border: Border(left: BorderSide(color: Palette.of(context).separator, width: 2))),
              child: Column(children: replies.map((r) => Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: _msgRow(r as Map<String, dynamic>))).toList()),
            ),
          ],
          const SizedBox(height: 6),
          GestureDetector(
            onTap: () => setState(() {
              _replyTo = post['id'].toString();
              _replyToName = post['author']?.toString();
            }),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(CupertinoIcons.arrowshape_turn_up_left, size: 14, color: Palette.of(context).accent),
              const SizedBox(width: 4),
              Text('Reply', style: AppleTheme.footnote(context).copyWith(color: Palette.of(context).accent, fontWeight: FontWeight.w600)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _moduleDoubtCard(Map<String, dynamic> m) {
    final isDoubt = m['is_doubt'] == true;
    final isStaff = m['staff'] == true;
    final module = m['module']?.toString() ?? 'Module';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppleCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(isDoubt ? CupertinoIcons.question_circle_fill : CupertinoIcons.chat_bubble_2_fill,
                size: 16, color: isDoubt ? AppleColors.orange : AppleColors.blue),
            const SizedBox(width: 6),
            Flexible(child: Text(module, style: AppleTheme.footnote(context).copyWith(fontWeight: FontWeight.w700))),
            if (isDoubt) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(color: AppleColors.orange.withOpacity(0.15), borderRadius: BorderRadius.zero),
                child: const Text('DOUBT', style: TextStyle(color: AppleColors.orange, fontSize: 9, fontWeight: FontWeight.w800)),
              ),
            ],
          ]),
          const SizedBox(height: 10),
          _msgRow({'author': m['author'], 'body': m['body'], 'is_staff': isStaff, 'role': isStaff ? 'instructor' : 'student'}),
          const SizedBox(height: 6),
          GestureDetector(
            onTap: () => setState(() {
              _replyModuleId = m['module_id']?.toString();
              // Answer lands in this student's private thread (fall back to author).
              _replyThreadUser = (m['thread_user_id']?.toString().isNotEmpty == true)
                  ? m['thread_user_id']?.toString()
                  : m['author_id']?.toString();
              _replyTo = null;
              _replyToName = '$module · ${m['author'] ?? 'student'}';
            }),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(CupertinoIcons.arrowshape_turn_up_left, size: 14, color: Palette.of(context).accent),
              const SizedBox(width: 4),
              Text('Answer', style: AppleTheme.footnote(context).copyWith(color: Palette.of(context).accent, fontWeight: FontWeight.w600)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _msgRow(Map<String, dynamic> m) {
    final isStaff = m['is_staff'] == true;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Avatar(name: m['author']?.toString() ?? '?', size: 32),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(m['author']?.toString() ?? 'Someone', style: AppleTheme.body(context).copyWith(fontSize: 14, fontWeight: FontWeight.w700)),
            if (isStaff) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(color: AppleColors.blue.withOpacity(0.14), borderRadius: BorderRadius.zero),
                child: Text(m['role']?.toString() == 'student' ? '' : 'Instructor',
                    style: const TextStyle(color: AppleColors.blue, fontSize: 10, fontWeight: FontWeight.w700)),
              ),
            ],
          ]),
          const SizedBox(height: 2),
          Text(m['body']?.toString() ?? '', style: AppleTheme.body(context).copyWith(fontSize: 14.5)),
        ]),
      ),
    ]);
  }

  Widget _composer(double hp) {
    final p = Palette.of(context);
    return SafeArea(
      top: false,
      child: Container(
        padding: EdgeInsets.fromLTRB(hp.clamp(12, 400).toDouble(), 8, hp.clamp(12, 400).toDouble(), 8),
        decoration: BoxDecoration(color: p.bg, border: Border(top: BorderSide(color: p.separator, width: 0.5))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_replyToName != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(children: [
                Icon(CupertinoIcons.arrowshape_turn_up_left, size: 13, color: p.secondary),
                const SizedBox(width: 4),
                Text('Replying to $_replyToName', style: AppleTheme.footnote(context)),
                const Spacer(),
                GestureDetector(onTap: () => setState(() { _replyTo = null; _replyToName = null; _replyModuleId = null; _replyThreadUser = null; }), child: Icon(CupertinoIcons.xmark, size: 14, color: p.secondary)),
              ]),
            ),
          Row(children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.zero, boxShadow: p.clay),
                child: AppleField(controller: _input, hint: (_replyTo == null && _replyModuleId == null) ? 'Ask a doubt or comment…' : 'Write a reply…'),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _sending ? null : _send,
              child: Container(
                width: 44, height: 44,
                decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle, boxShadow: [BoxShadow(color: p.accent.withOpacity(0.35), offset: const Offset(0, 5), blurRadius: 12, spreadRadius: -2)]),
                child: _sending
                    ? const Padding(padding: EdgeInsets.all(13), child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(CupertinoIcons.arrow_up, color: Colors.white, size: 20),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}
