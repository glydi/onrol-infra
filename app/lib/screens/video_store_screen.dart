import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import '../widgets/file_pick_stub.dart' if (dart.library.html) '../widgets/file_pick_web.dart';
import '../widgets/ui.dart';

/// Admin video store: upload videos to Cloudflare R2 and reuse them in lessons.
class VideoStoreScreen extends StatefulWidget {
  const VideoStoreScreen({super.key, required this.auth, this.onPick});
  final AuthService auth;
  // When provided, each video shows a "Use" button that returns its URL — lets
  // the Add Lesson flow pick from the store.
  final void Function(String url, String title)? onPick;

  @override
  State<VideoStoreScreen> createState() => _VideoStoreScreenState();
}

class _VideoStoreScreenState extends State<VideoStoreScreen> {
  bool _loading = true;
  bool _uploading = false;
  bool _r2 = true;
  List<dynamic> _videos = [];
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() { _loading = true; _err = null; });
    try {
      final r = await widget.auth.apiGet('/api/v1/manage/videos');
      final d = ApiClient.decode(r);
      _videos = (d['videos'] as List?) ?? [];
      _r2 = d['r2_enabled'] != false;
    } catch (_) {
      _err = 'Could not load the video store';
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  Future<void> _upload() async {
    final picked = await pickVideoFile();
    if (picked == null) return; // cancelled
    setState(() => _uploading = true);
    try {
      final resp = await widget.auth.apiUpload('/api/v1/manage/videos/upload',
          bytes: picked.bytes, filename: picked.name, fields: {'title': picked.name});
      ApiClient.decode(resp); // throws on non-2xx
      _toast('Uploaded "${picked.name}"');
      await _load();
    } on ApiException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('Upload failed');
    }
    if (mounted) setState(() => _uploading = false);
  }

  String _size(num b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(0)} MB';
    return '${(b / 1024).toStringAsFixed(0)} KB';
  }

  Future<void> _delete(String id, String title) async {
    final yes = await showSquareConfirm(context,
        title: 'Delete video',
        message: 'Delete "$title" from the store and R2? Lessons using its URL will stop playing.',
        confirmLabel: 'Delete', destructive: true);
    if (!yes) return;
    try {
      await widget.auth.apiDelete('/api/v1/manage/videos/$id');
      _toast('Deleted');
      _load();
    } catch (_) { _toast('Could not delete'); }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SquareScope(child: Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(title: const Text('Video Store'), backgroundColor: p.bg, elevation: 0),
      body: _loading
          ? const Center(child: CupertinoActivityIndicator())
          : RefreshIndicator(
              color: p.accent,
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
                children: [
                  Text('Video Store', style: AppleTheme.largeTitle(context)),
                  Text('${_videos.length} video${_videos.length == 1 ? '' : 's'} · stored in Cloudflare R2', style: AppleTheme.subhead(context)),
                  const SizedBox(height: 16),
                  if (!_r2)
                    AppleCard(square: true, child: Text('Video storage (R2) is not configured on the server.', style: AppleTheme.footnote(context)))
                  else
                    PrimaryButton(
                      label: _uploading ? 'Uploading…' : 'Upload video',
                      icon: CupertinoIcons.cloud_upload,
                      square: true,
                      busy: _uploading,
                      onPressed: _uploading ? null : _upload,
                    ),
                  const SizedBox(height: 18),
                  if (_err != null)
                    AppleCard(square: true, child: Text(_err!, style: AppleTheme.footnote(context)))
                  else if (_videos.isEmpty)
                    AppleCard(square: true, child: Text('No videos yet. Upload one to get started.', style: AppleTheme.footnote(context)))
                  else
                    ..._videos.map((v) => _row(v as Map<String, dynamic>)),
                ],
              ),
            ),
    ));
  }

  Widget _row(Map<String, dynamic> v) {
    final p = Palette.of(context);
    final url = v['url']?.toString() ?? '';
    final title = v['title']?.toString() ?? 'Video';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppleCard(
        square: true,
        child: Row(children: [
          Container(
            width: 40, height: 40, alignment: Alignment.center,
            decoration: BoxDecoration(color: p.accent.withOpacity(0.14)),
            child: Icon(CupertinoIcons.play_rectangle_fill, color: p.accent, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: AppleTheme.body(context), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(_size((v['size_bytes'] as num?) ?? 0), style: AppleTheme.footnote(context)),
          ])),
          if (widget.onPick != null)
            HoverTap(
              onTap: () => widget.onPick!(url, title),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: p.accent),
                child: const Text('Use', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            )
          else ...[
            HoverTap(
              onTap: () { Clipboard.setData(ClipboardData(text: url)); _toast('URL copied'); },
              child: Icon(CupertinoIcons.doc_on_doc, size: 20, color: p.secondary),
            ),
            const SizedBox(width: 14),
            HoverTap(
              onTap: () => _delete(v['id'].toString(), title),
              child: const Icon(CupertinoIcons.trash, size: 20, color: AppleColors.red),
            ),
          ],
        ]),
      ),
    );
  }
}
