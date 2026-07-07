import 'dart:async';

import 'package:flutter/cupertino.dart' hide Text;
import 'package:flutter/material.dart' hide Text;
import 'package:onrol_app/widgets/upper_text.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import '../widgets/ui.dart';

/// The standing "Ask Mentor" queue: every student question from live sessions in
/// the mentor's courses, unanswered first. The mentor can answer any time — the
/// answer is delivered to the student who asked (same endpoint the live room uses).
class AskMentorQueueScreen extends StatefulWidget {
  const AskMentorQueueScreen({super.key, required this.auth});
  final AuthService auth;

  @override
  State<AskMentorQueueScreen> createState() => _AskMentorQueueScreenState();
}

class _AskMentorQueueScreenState extends State<AskMentorQueueScreen> {
  List<Map<String, dynamic>> _questions = [];
  int _waiting = 0;
  bool _loading = true;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 12), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final d = ApiClient.decode(await widget.auth.apiGet('/api/v1/manage/mentor-questions'));
      final qs = ((d['questions'] as List?) ?? []).map((e) => (e as Map).cast<String, dynamic>()).toList();
      if (mounted) setState(() {
        _questions = qs;
        _waiting = (d['waiting'] as num?)?.toInt() ?? qs.where((q) => q['answered'] != true).length;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  Future<void> _answer(Map<String, dynamic> q) async {
    final ctl = TextEditingController();
    final ok = await showFormSheet(
      context,
      square: true,
      title: 'Reply to ${(q['name']?.toString().isNotEmpty ?? false) ? q['name'] : 'student'}',
      builder: (_) => [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Palette.of(context).card2, borderRadius: BorderRadius.zero),
          child: Text(q['body']?.toString() ?? '', style: AppleTheme.body(context)),
        ),
        const SizedBox(height: 12),
        sheetField(ctl, 'Your reply…', CupertinoIcons.text_bubble, keyboard: TextInputType.multiline, square: true),
      ],
      onSubmit: () async {
        if (ctl.text.trim().isEmpty) return 'Reply required';
        // Reply straight into the student's thread (module or course-general).
        final mid = q['module_id']?.toString() ?? '';
        final path = mid.isNotEmpty ? '/api/v1/modules/$mid/comments' : '/api/v1/courses/${q['course_id']}/comments';
        try {
          await widget.auth.apiPost(path, {'body': ctl.text.trim(), 'thread_user_id': q['thread_user_id']});
          return null;
        } on ApiException catch (e) {
          return e.message;
        } catch (_) {
          return 'Could not send';
        }
      },
    );
    if (ok == true) {
      _toast('Reply sent');
      _load(silent: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      color: p.bg,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Row(children: [
            Text('Ask Mentor', style: AppleTheme.largeTitle(context)),
            const SizedBox(width: 10),
            if (_waiting > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: AppleColors.orange, borderRadius: BorderRadius.zero),
                child: Text('$_waiting waiting', style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w800)),
              ),
            const Spacer(),
            IconButton(icon: Icon(CupertinoIcons.refresh, color: p.secondary), onPressed: () => _load()),
          ]),
        ),
        Expanded(
          child: _loading && _questions.isEmpty
              ? const Center(child: CupertinoActivityIndicator())
              : _questions.isEmpty
                  ? Center(child: Text('No questions yet.', style: AppleTheme.subhead(context)))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                        itemCount: _questions.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (_, i) => _card(_questions[i], p),
                      ),
                    ),
        ),
      ]),
    );
  }

  Widget _card(Map<String, dynamic> q, Palette p) {
    final name = q['name']?.toString().isNotEmpty == true ? q['name'].toString() : 'Student';
    final where = [q['course'], q['where']].where((s) => (s?.toString().isNotEmpty ?? false)).map((s) => s.toString()).join(' · ');
    final isDoubt = q['is_doubt'] == true;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.zero,
        border: Border.all(color: AppleColors.orange.withValues(alpha: 0.5), width: 1.4),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(name, style: AppleTheme.headline(context))),
          if (isDoubt)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: const Color(0xFF2D7DF6).withValues(alpha: 0.16), borderRadius: BorderRadius.zero),
              child: const Text('Doubt', style: TextStyle(color: Color(0xFF2D7DF6), fontSize: 10.5, fontWeight: FontWeight.w800)),
            ),
        ]),
        if (where.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(where, style: AppleTheme.footnote(context))),
        const SizedBox(height: 8),
        Text(q['body']?.toString() ?? '', style: AppleTheme.body(context)),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: PrimaryButton(label: 'Reply', icon: CupertinoIcons.reply_thick_solid, square: true, onPressed: () => _answer(q)),
        ),
      ]),
    );
  }
}
