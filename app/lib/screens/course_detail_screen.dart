import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'discussion_screen.dart';
import 'video_player_screen.dart';

/// Student course view — modules, lessons, video playback (R2), mark complete.
class CourseDetailScreen extends StatefulWidget {
  const CourseDetailScreen({super.key, required this.auth, required this.courseId, required this.title});
  final AuthService auth;
  final String courseId;
  final String title;

  @override
  State<CourseDetailScreen> createState() => _CourseDetailScreenState();
}

class _CourseDetailScreenState extends State<CourseDetailScreen> {
  bool _loading = true;
  List<dynamic> _modules = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.auth.apiGet('/api/v1/me/courses/${widget.courseId}/content');
      _modules = (ApiClient.decode(r)['modules'] as List?) ?? [];
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  Future<void> _open(Map<String, dynamic> l) async {
    final type = l['type']?.toString() ?? 'text';
    final url = l['url']?.toString() ?? '';
    final wm = widget.auth.user?.email ?? 'student';

    if (url.isEmpty && type != 'text') {
      _toast('No content link yet.');
      return;
    }
    if (type == 'video') {
      // Streams the R2/HLS video with custom controls (no download) + watermark.
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VideoPlayerScreen(url: url, watermark: wm, title: l['title']?.toString() ?? 'Video', authToken: widget.auth.token)));
    } else if (type == 'link') {
      // Open the resource in a new tab / external browser (avoids iframe blocks).
      final uri = Uri.tryParse(url);
      if (uri != null) {
        await launchUrl(uri, mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank');
      } else {
        _toast('Invalid link.');
      }
    } else {
      _showText(l);
    }
    _complete(l['id'].toString());
  }

  Future<void> _complete(String lessonId) async {
    try {
      await widget.auth.apiPost('/api/v1/me/lessons/$lessonId/complete', {});
      _load();
    } catch (_) {}
  }

  void _showText(Map<String, dynamic> l) {
    final p = Palette.of(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (_, ctrl) => Container(
          margin: const EdgeInsets.all(10),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.zero),
          child: ListView(controller: ctrl, children: [
            Text(l['title']?.toString() ?? 'Lesson', style: AppleTheme.title2(context)),
            const SizedBox(height: 12),
            Text((l['url']?.toString() ?? '').isEmpty ? 'No content.' : l['url'].toString(), style: AppleTheme.body(context)),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: p.bg.withOpacity(0.9),
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(icon: const Icon(CupertinoIcons.chevron_left), onPressed: () => Navigator.pop(context)),
        title: Text(widget.title, style: AppleTheme.headline(context)),
        actions: [
          IconButton(
            icon: const Icon(CupertinoIcons.chat_bubble_2_fill),
            tooltip: 'Doubts & Discussion',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => DiscussionScreen(auth: widget.auth, courseId: widget.courseId, title: widget.title))),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CupertinoActivityIndicator())
          : RefreshIndicator(
              color: p.accent,
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
                children: [
                  if (_modules.isEmpty)
                    AppleCard(child: Text('No content yet. Your instructor will add lessons soon.', style: AppleTheme.footnote(context)))
                  else
                    ..._modules.map((m) => _moduleCard(m as Map<String, dynamic>)),
                ],
              ),
            ),
    );
  }

  Widget _moduleCard(Map<String, dynamic> m) {
    final lessons = (m['lessons'] as List?) ?? [];
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Text(m['title']?.toString() ?? 'Module', style: AppleTheme.title2(context)),
          ),
          AppleCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: List.generate(lessons.length, (i) {
                final l = lessons[i] as Map<String, dynamic>;
                final done = l['completed'] == true;
                final type = l['type']?.toString() ?? 'text';
                return Column(children: [
                  if (i > 0) Divider(height: 1, indent: 56, color: Palette.of(context).separator),
                  ListTile(
                    onTap: () => _open(l),
                    leading: Container(
                      width: 36, height: 36,
                      decoration: BoxDecoration(color: _color(type).withOpacity(0.12), borderRadius: BorderRadius.zero),
                      child: Icon(_icon(type), size: 18, color: _color(type)),
                    ),
                    title: Text(l['title']?.toString() ?? '', style: AppleTheme.body(context)),
                    subtitle: Text(_typeLabel(type), style: AppleTheme.footnote(context)),
                    trailing: done
                        ? const Icon(CupertinoIcons.checkmark_alt_circle_fill, color: AppleColors.green, size: 22)
                        : Icon(CupertinoIcons.chevron_right, size: 18, color: Palette.of(context).secondary),
                  ),
                ]);
              }),
            ),
          ),
        ],
      ),
    );
  }

  IconData _icon(String t) => switch (t) {
        'video' => CupertinoIcons.play_circle_fill,
        'link' => CupertinoIcons.link,
        _ => CupertinoIcons.doc_text_fill,
      };
  Color _color(String t) => switch (t) {
        'video' => AppleColors.red,
        'link' => AppleColors.teal,
        _ => AppleColors.blue,
      };
  String _typeLabel(String t) => switch (t) {
        'video' => 'Video',
        'link' => 'Link',
        _ => 'Reading',
      };
}
