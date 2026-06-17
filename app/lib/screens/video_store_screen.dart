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
  double _progress = 0; // 0..1 during chunked upload
  // Live upload breakdown shown on screen.
  String _upName = '';
  int _upPart = 0, _upTotalParts = 0;
  int _upDone = 0, _upTotal = 0;
  List<dynamic> _videos = [];
  String? _err;

  static const _chunkSize = 8 * 1024 * 1024; // 8 MB pieces

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

  // Chunked upload: split the file into pieces, upload each as an R2 multipart
  // part, then complete — so even multi-GB files upload reliably. R2 stitches the
  // pieces back into one video; the admin only ever sees one entry.
  Future<void> _upload() async {
    final picked = await pickVideoFile();
    if (picked == null) return; // cancelled
    final bytes = picked.bytes;
    setState(() {
      _uploading = true; _progress = 0;
      _upName = picked.name; _upDone = 0; _upTotal = bytes.length;
      _upPart = 0; _upTotalParts = (bytes.length / _chunkSize).ceil();
    });
    try {
      // 1. init multipart upload
      final initR = await widget.auth.apiPost('/api/v1/manage/videos/upload/init',
          {'filename': picked.name, 'content_type': 'video/mp4'});
      final init = ApiClient.decode(initR);
      final uploadId = init['upload_id'].toString();
      final key = init['key'].toString();
      final qid = Uri.encodeQueryComponent(uploadId);
      final qkey = Uri.encodeQueryComponent(key);

      // 2. upload each chunk as a part
      final parts = <Map<String, dynamic>>[];
      var part = 1;
      for (var off = 0; off < bytes.length; off += _chunkSize) {
        final end = (off + _chunkSize < bytes.length) ? off + _chunkSize : bytes.length;
        final chunk = bytes.sublist(off, end);
        final pr = await widget.auth.apiPostBytes(
            '/api/v1/manage/videos/upload/part?upload_id=$qid&key=$qkey&part=$part', chunk);
        final pd = ApiClient.decode(pr);
        parts.add({'part_number': part, 'etag': pd['etag']});
        if (mounted) setState(() {
          _upPart = part; _upDone = end; _progress = end / bytes.length;
        });
        part++;
      }

      // 3. complete — R2 reassembles into one object
      final cr = await widget.auth.apiPost('/api/v1/manage/videos/upload/complete', {
        'upload_id': uploadId, 'key': key, 'title': picked.name, 'size': bytes.length, 'parts': parts,
      });
      ApiClient.decode(cr);
      _toast('Uploaded "${picked.name}"');
      await _load();
    } on ApiException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('Upload failed');
    }
    if (mounted) setState(() { _uploading = false; _progress = 0; });
  }

  String _size(num b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(0)} MB';
    return '${(b / 1024).toStringAsFixed(0)} KB';
  }

  // Live upload breakdown: filename, a box per 8 MB chunk (fills as it uploads),
  // the bar, and "Part X of Y · Z / W MB".
  Widget _uploadPanel() {
    final p = Palette.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: p.card, border: Border.all(color: p.separator)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(CupertinoIcons.cloud_upload_fill, size: 18, color: p.accent),
          const SizedBox(width: 8),
          Expanded(child: Text(_upName, style: AppleTheme.body(context), maxLines: 1, overflow: TextOverflow.ellipsis)),
          Text('${(_progress * 100).toStringAsFixed(0)}%', style: AppleTheme.body(context).copyWith(color: p.accent, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 10),
        // One block per chunk — solid = uploaded, faded = in progress, grey = pending.
        Wrap(spacing: 4, runSpacing: 4, children: List.generate(_upTotalParts, (i) {
          final done = i < _upPart;
          final active = i == _upPart;
          return Container(
            width: 20, height: 11,
            decoration: BoxDecoration(color: done ? p.accent : (active ? p.accent.withOpacity(0.45) : p.separator)),
          );
        })),
        const SizedBox(height: 12),
        LinearProgressIndicator(value: _progress == 0 ? null : _progress, color: p.accent, backgroundColor: p.separator),
        const SizedBox(height: 8),
        Text('Part $_upPart of $_upTotalParts · ${_size(_upDone)} / ${_size(_upTotal)}', style: AppleTheme.footnote(context)),
      ]),
    );
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
                  else ...[
                    PrimaryButton(
                      label: _uploading ? 'Uploading… ${(_progress * 100).toStringAsFixed(0)}%' : 'Upload video',
                      icon: CupertinoIcons.cloud_upload,
                      square: true,
                      busy: _uploading,
                      onPressed: _uploading ? null : _upload,
                    ),
                    if (_uploading) _uploadPanel(),
                  ],
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
