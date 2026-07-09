import 'dart:typed_data';

import 'package:flutter/cupertino.dart' hide Text;
import 'package:flutter/material.dart' hide Text;
import 'package:onrol_app/widgets/upper_text.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import '../widgets/file_pick_stub.dart' if (dart.library.html) '../widgets/file_pick_web.dart';
import '../widgets/ui.dart';
import 'video_player_screen.dart';

/// Admin video store: upload videos to Cloudflare R2 and reuse them in lessons.
class VideoStoreScreen extends StatefulWidget {
  const VideoStoreScreen({super.key, required this.auth, this.onPick});
  final AuthService auth;
  // When provided, each video shows a "Use" button that returns its id + URL —
  // lets the Add Lesson / Add Live flows pick from the store.
  final void Function(String id, String url, String title)? onPick;

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

  static const _chunkSize = 16 * 1024 * 1024; // 16 MB pieces — fewer round-trips = faster

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
    // Poll while anything is still transcoding so status flips to "ready" live.
    if (mounted && _videos.any((v) => (v as Map)['status'] == 'processing')) {
      Future.delayed(const Duration(seconds: 5), () { if (mounted) _load(); });
    }
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  // Chunked upload: split the file into pieces, upload each as an R2 multipart
  // part, then complete — so even multi-GB files upload reliably. R2 stitches the
  // pieces back into one video; the admin only ever sees one entry.
  Future<void> _upload() async {
    final picked = await pickVideoFile();
    if (picked == null) return; // cancelled
    final total = picked.size;
    setState(() {
      _uploading = true; _progress = 0;
      _upName = picked.name; _upDone = 0; _upTotal = total;
      _upPart = 0; _upTotalParts = (total / _chunkSize).ceil();
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

      // 2. Ask for presigned URLs so the browser can PUT each part DIRECTLY to R2
      //    at full bandwidth (no double hop through our server). Best-effort — if
      //    signing/CORS isn't available we fall back to the proxy upload path.
      final numParts = (total / _chunkSize).ceil();
      Map<String, dynamic> signed = {};
      try {
        final sr = await widget.auth.apiPost('/api/v1/manage/videos/upload/sign', {
          'key': key, 'upload_id': uploadId,
          'parts': [for (var i = 1; i <= numParts; i++) i],
        });
        signed = (ApiClient.decode(sr)['urls'] as Map?)?.cast<String, dynamic>() ?? {};
      } catch (_) {/* fall back to proxy */}
      var directEnabled = signed.isNotEmpty;

      // 3. Upload parts CONCURRENTLY with retry, preferring direct-to-R2 and
      //    falling back to the proxy. A pool keeps the link saturated; each part
      //    survives transient failures instead of aborting the whole upload. One
      //    8 MB slice per worker keeps memory bounded (~concurrency * 8 MB).
      final etags = List<String?>.filled(numParts, null);
      var nextIndex = 0; // next 0-based part to claim (event loop = atomic)
      var doneParts = 0, doneBytes = 0;
      Object? failure;

      Future<String?> putDirect(int partNum, Uint8List chunk) async {
        final u = signed['$partNum']?.toString();
        if (u == null || u.isEmpty) return null;
        final resp = await http.put(Uri.parse(u), body: chunk);
        if (resp.statusCode == 200) return (resp.headers['etag'] ?? '').replaceAll('"', '');
        return null;
      }

      Future<String?> putProxy(int partNum, Uint8List chunk) async {
        final pr = await widget.auth.apiPostBytes(
            '/api/v1/manage/videos/upload/part?upload_id=$qid&key=$qkey&part=$partNum', chunk);
        return ApiClient.decode(pr)['etag']?.toString();
      }

      Future<void> worker() async {
        while (failure == null) {
          final i = nextIndex;
          if (i >= numParts) return;
          nextIndex++;
          final off = i * _chunkSize;
          final end = (off + _chunkSize < total) ? off + _chunkSize : total;
          final partNum = i + 1;
          try {
            final chunk = await picked.read(off, end);
            String? etag;
            if (directEnabled) {
              for (var a = 0; a < 2 && (etag == null || etag.isEmpty); a++) {
                try { etag = await putDirect(partNum, chunk); } catch (_) {}
                if (etag == null || etag.isEmpty) await Future.delayed(Duration(milliseconds: 400 * (a + 1)));
              }
              if (etag == null || etag.isEmpty) directEnabled = false; // give up on direct for the rest
            }
            for (var a = 0; a < 3 && (etag == null || etag.isEmpty); a++) {
              try { etag = await putProxy(partNum, chunk); } catch (_) {}
              if (etag == null || etag.isEmpty) await Future.delayed(Duration(milliseconds: 600 * (a + 1)));
            }
            if (etag == null || etag.isEmpty) {
              failure = Exception('Part $partNum failed to upload');
              return;
            }
            etags[i] = etag;
            doneParts++;
            doneBytes += end - off;
            if (mounted) setState(() {
              _upPart = doneParts; _upDone = doneBytes; _progress = doneBytes / total;
            });
          } catch (e) {
            failure = e; // stop the pool; surfaced below
            return;
          }
        }
      }

      // Direct-to-R2 PUTs go over HTTP/2 (multiplexed), so we can push more than
      // the classic 6-per-host limit; the proxy fallback still benefits too.
      const concurrency = 8;
      await Future.wait(List.generate(concurrency, (_) => worker()));
      if (failure != null) throw failure!;
      if (etags.any((e) => e == null || e.isEmpty)) throw Exception('A part failed to upload');

      final parts = <Map<String, dynamic>>[
        for (var i = 0; i < numParts; i++) {'part_number': i + 1, 'etag': etags[i]},
      ];

      // 3. complete — R2 reassembles into one object
      final cr = await widget.auth.apiPost('/api/v1/manage/videos/upload/complete', {
        'upload_id': uploadId, 'key': key, 'title': picked.name, 'size': total, 'parts': parts,
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

  // Preview the video in the full player (HLS once ready, else the source mp4) so
  // an admin can actually watch what's in the store. authToken signs the
  // encrypted-HLS key requests; the watermark carries the admin's identity.
  Future<void> _play(String url, String title) async {
    if (url.isEmpty) { _toast('No video URL yet'); return; }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => VideoPlayerScreen(
        url: url,
        watermark: widget.auth.user?.email ?? 'admin',
        title: title,
        authToken: widget.auth.token,
      )));
  }

  Future<void> _rename(String id, String current) async {
    final ctl = TextEditingController(text: current);
    final ok = await showFormSheet(context, square: true, title: 'Rename video',
        builder: (_) => [sheetField(ctl, 'Video title', CupertinoIcons.textformat)],
        onSubmit: () async {
      if (ctl.text.trim().isEmpty) return 'Title required';
      try {
        await widget.auth.apiPatch('/api/v1/manage/videos/$id', {'title': ctl.text.trim()});
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) { _toast('Renamed'); _load(); }
  }

  Future<void> _delete(String id, String title) async {
    final yes = await showSquareConfirm(context,
        title: 'Delete video',
        message: 'Delete "$title"? Removes the source + HLS from R2; lessons using it stop playing.',
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
    final status = v['status']?.toString() ?? 'ready';
    final ready = status == 'ready';
    final processing = status == 'processing';
    final statusColor = ready ? AppleColors.green : (processing ? AppleColors.orange : AppleColors.red);
    final statusText = ready ? 'HLS ready' : (processing ? 'Processing…' : 'Transcode failed (plays source)');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppleCard(
        square: true,
        child: Row(children: [
          HoverTap(
            onTap: () => _play(url, title),
            child: Container(
              width: 40, height: 40, alignment: Alignment.center,
              decoration: BoxDecoration(color: p.accent.withOpacity(0.14)),
              child: processing
                  ? const CupertinoActivityIndicator(radius: 9)
                  : Icon(CupertinoIcons.play_rectangle_fill, color: p.accent, size: 20),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: HoverTap(
            onTap: () => _showDetails(v),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppleTheme.body(context), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Row(children: [
                Text(_metaLine(v), style: AppleTheme.footnote(context)),
                const SizedBox(width: 5),
                Icon(CupertinoIcons.info_circle, size: 12, color: p.secondary),
              ]),
            ]),
          )),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: statusColor.withOpacity(0.15)),
            child: Text(statusText, style: TextStyle(color: statusColor, fontSize: 10.5, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 10),
          if (widget.onPick != null)
            HoverTap(
              // Allow picking even while processing — it'll switch to HLS once ready.
              onTap: () => widget.onPick!(v['id']?.toString() ?? '', url, title),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: p.accent),
                child: const Text('Use', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            )
          else ...[
            HoverTap(
              onTap: () => _play(url, title),
              child: Icon(CupertinoIcons.play_circle, size: 22, color: p.accent),
            ),
            const SizedBox(width: 14),
            HoverTap(
              onTap: () { Clipboard.setData(ClipboardData(text: url)); _toast('URL copied'); },
              child: Icon(CupertinoIcons.doc_on_doc, size: 20, color: p.secondary),
            ),
            const SizedBox(width: 14),
            HoverTap(
              onTap: () { if (!processing) _retranscode(v['id'].toString()); },
              child: Icon(CupertinoIcons.arrow_2_circlepath, size: 20, color: processing ? p.separator : p.secondary),
            ),
            const SizedBox(width: 14),
            HoverTap(
              onTap: () => _rename(v['id'].toString(), title),
              child: Icon(CupertinoIcons.pencil, size: 20, color: p.secondary),
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

  // One-line summary under the title (size · duration).
  String _metaLine(Map<String, dynamic> v) {
    final size = _size((v['size_bytes'] as num?) ?? 0);
    final dur = (v['duration_seconds'] as num?)?.toInt() ?? 0;
    return dur > 0 ? '$size · ${_dur(dur)}' : size;
  }

  static String _dur(int s) {
    String two(int n) => n.toString().padLeft(2, '0');
    return s >= 3600 ? '${s ~/ 3600}:${two((s % 3600) ~/ 60)}:${two(s % 60)}' : '${s ~/ 60}:${two(s % 60)}';
  }

  // Full metadata for a video, with copyable URLs/ID.
  void _showDetails(Map<String, dynamic> v) {
    final p = Palette.of(context);
    final dur = (v['duration_seconds'] as num?)?.toInt() ?? 0;
    final size = (v['size_bytes'] as num?)?.toInt() ?? 0;
    final created = DateTime.tryParse(v['created_at']?.toString() ?? '')?.toLocal();
    final status = v['status']?.toString() ?? '';
    final rows = <(String, String, bool)>[
      ('Title', v['title']?.toString() ?? '', false),
      ('Status', status == 'ready' ? 'HLS ready' : (status == 'processing' ? 'Processing…' : 'Transcode failed (plays source)'), false),
      ('Duration', dur > 0 ? _dur(dur) : '—', false),
      ('Size', _size(size), false),
      ('Format', (v['content_type']?.toString().isNotEmpty ?? false) ? v['content_type'].toString() : '—', false),
      ('Encrypted', v['encrypted'] == true ? 'Yes (AES-128)' : 'No', false),
      ('Uploaded', created != null ? '${created.day}/${created.month}/${created.year}' : '—', false),
      ('HLS URL', v['hls_url']?.toString() ?? '', true),
      ('Source URL', v['url']?.toString() ?? '', true),
      ('Asset ID', v['id']?.toString() ?? '', true),
    ];
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => SquareScope(
        square: true,
        child: Container(
          margin: const EdgeInsets.all(10),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: p.card),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Video details', style: AppleTheme.headline(context)),
              const SizedBox(height: 14),
              for (final (label, val, copyable) in rows)
                if (val.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 11),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(width: 92, child: Text(label, style: AppleTheme.footnote(context))),
                      Expanded(child: Text(val, style: AppleTheme.body(context), maxLines: copyable ? 1 : 3, overflow: TextOverflow.ellipsis)),
                      if (copyable)
                        HoverTap(
                          onTap: () { Clipboard.setData(ClipboardData(text: val)); _toast('Copied'); },
                          child: Padding(padding: const EdgeInsets.only(left: 8), child: Icon(CupertinoIcons.doc_on_doc, size: 16, color: p.secondary)),
                        ),
                    ]),
                  ),
              const SizedBox(height: 6),
              PrimaryButton(label: 'Close', square: true, onPressed: () => Navigator.of(ctx).pop()),
            ]),
          ),
        ),
      ),
    );
  }

  // Re-run HLS segmentation for an existing video (no re-encode, no quality loss).
  Future<void> _retranscode(String id) async {
    try {
      await widget.auth.apiPost('/api/v1/manage/videos/$id/retranscode', {});
      _toast('Re-processing…');
      _load();
    } catch (_) { _toast('Could not re-process'); }
  }
}
