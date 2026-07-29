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
  List<Map<String, dynamic>> _folders = [];
  String _folder = ''; // '' = All, '__none__' = Unfiled, else a folder id
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
      try {
        final fr = await widget.auth.apiGet('/api/v1/manage/video-folders');
        _folders = ((ApiClient.decode(fr)['folders'] as List?) ?? [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
      } catch (_) {}
      // Landing shows the folders view (_folder == ''); tapping a folder opens it.
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
              // Constrain the content width so cards aren't stretched full-screen
              // on wide monitors.
              child: Center(child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
                children: [
                  Text('Video Store', style: AppleTheme.largeTitle(context)),
                  Text('${_videos.length} video${_videos.length == 1 ? '' : 's'} · stored in Cloudflare R2', style: AppleTheme.subhead(context)),
                  const SizedBox(height: 16),
                  if (!_r2)
                    AppleCard(square: true, child: Text('Video storage (R2) is not configured on the server.', style: AppleTheme.footnote(context)))
                  else ...[
                    // Compact and quiet: a full-width CTA that scale-popped on
                    // hover/press dominated a page that's really a file list.
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SmallActionButton(
                        label: _uploading
                            ? 'Uploading… ${(_progress * 100).toStringAsFixed(0)}%'
                            : 'Upload video',
                        icon: CupertinoIcons.cloud_upload,
                        onPressed: _uploading ? null : _upload,
                      ),
                    ),
                    if (_uploading) _uploadPanel(),
                  ],
                  const SizedBox(height: 18),
                  if (_err != null)
                    AppleCard(square: true, child: Text(_err!, style: AppleTheme.footnote(context)))
                  else ...[
                    Builder(builder: (_) {
                      // Landing = folders view; drilling in = that folder's videos.
                      if (_folder.isEmpty) {
                        final unfiled = _videos.where((v) => ((v as Map)['folder_id']?.toString() ?? '').isEmpty).length;
                        final cards = <Widget>[
                          _videoFolderCard('Unfiled', '__none__', unfiled, null),
                          for (final f in _folders) _videoFolderCard(f['name']?.toString() ?? 'Folder', f['id'].toString(), (f['videos'] as num?)?.toInt() ?? 0, f),
                        ];
                        final w = MediaQuery.of(context).size.width;
                        final cols = w >= 760 ? 4 : (w >= 520 ? 3 : 2);
                        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Row(children: [
                            Expanded(child: Text('Folders — tap to open.', style: AppleTheme.footnote(context))),
                            _folderActionBtn(CupertinoIcons.folder_badge_plus, 'New folder', _newFolder),
                          ]),
                          const SizedBox(height: 12),
                          GridView.count(crossAxisCount: cols, childAspectRatio: 1, crossAxisSpacing: 10, mainAxisSpacing: 10, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), children: cards),
                        ]);
                      }
                      // Inside a folder.
                      final f = _folders.firstWhere((e) => e['id'].toString() == _folder, orElse: () => <String, dynamic>{});
                      final name = _folder == '__none__' ? 'Unfiled' : (f['name']?.toString() ?? 'Folder');
                      final vids = _videos.where((v) {
                        final fid = (v as Map)['folder_id']?.toString() ?? '';
                        return _folder == '__none__' ? fid.isEmpty : fid == _folder;
                      }).toList();
                      final w = MediaQuery.of(context).size.width;
                      final cols = w >= 760 ? 3 : (w >= 520 ? 2 : 1);
                      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          HoverTap(onTap: () => setState(() => _folder = ''), child: Icon(CupertinoIcons.chevron_back, size: 20, color: p.accent)),
                          const SizedBox(width: 6),
                          Expanded(child: Text(name, style: AppleTheme.title2(context))),
                          if (f.isNotEmpty) ...[
                            _folderActionBtn(CupertinoIcons.pencil, 'Rename', () => _renameFolder(f)),
                            const SizedBox(width: 8),
                            _folderActionBtn(CupertinoIcons.trash, 'Delete', () => _deleteFolder(f), color: AppleColors.red),
                          ],
                        ]),
                        const SizedBox(height: 12),
                        if (vids.isEmpty)
                          AppleCard(square: true, child: Text('No videos in this folder. Upload one, or move videos here.', style: AppleTheme.footnote(context)))
                        else
                          GridView.count(
                            crossAxisCount: cols, childAspectRatio: 1, crossAxisSpacing: 10, mainAxisSpacing: 10,
                            shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
                            children: vids.map((v) => _gridCard(v as Map<String, dynamic>)).toList(),
                          ),
                      ]);
                    }),
                  ],
                ],
              ))),
            ),
    ));
  }

  // Folder chips (Unfiled / each folder) with a New-folder button. Long-press a
  // folder chip to rename or delete it. There's deliberately no "All" chip —
  // the store is browsed one folder at a time.
  Widget _folderBar() {
    final unfiled = _videos.where((v) => ((v as Map)['folder_id']?.toString() ?? '').isEmpty).length;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        _folderChip('Unfiled', '__none__', unfiled, null),
        for (final f in _folders) ...[
          const SizedBox(width: 6),
          _folderChip(f['name']?.toString() ?? 'Folder', f['id'].toString(), (f['videos'] as num?)?.toInt() ?? 0, f),
        ],
        const SizedBox(width: 6),
        GestureDetector(
          onTap: _newFolder,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: Palette.of(context).card2, border: Border.all(color: Palette.of(context).separator)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(CupertinoIcons.folder_badge_plus, size: 15, color: Palette.of(context).accent),
              const SizedBox(width: 5),
              Text('New folder', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Palette.of(context).accent)),
            ]),
          ),
        ),
      ]),
    );
  }

  // Square folder card for the landing folders view.
  Widget _videoFolderCard(String label, String value, int count, Map<String, dynamic>? folder) {
    final p = Palette.of(context);
    return GestureDetector(
      onTap: () => setState(() => _folder = value),
      child: AppleCard(square: true, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(folder != null ? CupertinoIcons.folder_fill : CupertinoIcons.tray_fill, size: 42, color: p.accent),
        const SizedBox(height: 10),
        Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: AppleTheme.headline(context)),
        const SizedBox(height: 4),
        Text('$count video${count == 1 ? '' : 's'}', style: AppleTheme.footnote(context)),
      ])),
    );
  }

  Widget _folderChip(String label, String value, int count, Map<String, dynamic>? folder) {
    final p = Palette.of(context);
    final on = _folder == value;
    return GestureDetector(
      onTap: () => setState(() => _folder = value),
      onLongPress: folder == null ? null : () => _folderMenu(folder),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: on ? p.accent : p.card2, border: Border.all(color: on ? p.accent : p.separator)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (folder != null) Padding(padding: const EdgeInsets.only(right: 5), child: Icon(CupertinoIcons.folder_fill, size: 14, color: on ? Colors.white : p.secondary)),
          Text('$label · $count', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: on ? Colors.white : p.label)),
        ]),
      ),
    );
  }

  Future<void> _newFolder() async {
    final name = TextEditingController();
    final ok = await showFormSheet(context, square: true, title: 'New folder', builder: (_) => [
      sheetField(name, 'Folder name', CupertinoIcons.folder),
    ], onSubmit: () async {
      if (name.text.trim().isEmpty) return 'Name required';
      try {
        await widget.auth.apiPost('/api/v1/manage/video-folders', {'name': name.text.trim()});
        return null;
      } on ApiException catch (e) {
        return e.message;
      }
    });
    if (ok == true) { _toast('Folder created'); _load(); }
  }

  // Long-press menu on a folder chip → rename or delete (same as the visible
  // buttons shown when the folder is open).
  Future<void> _folderMenu(Map<String, dynamic> f) async {
    final v = await showSquareMenu(context, title: f['name']?.toString() ?? 'Folder', items: const [
      SquareMenuItem('Rename', value: 'rename', icon: CupertinoIcons.pencil),
      SquareMenuItem('Delete folder', value: 'delete', icon: CupertinoIcons.trash),
    ]);
    if (v == 'rename') _renameFolder(f);
    if (v == 'delete') _deleteFolder(f);
  }

  Widget _folderActionBtn(IconData icon, String label, VoidCallback onTap, {Color? color}) =>
      _FolderActionBtn(icon: icon, label: label, onTap: onTap, color: color ?? Palette.of(context).accent);

  Future<void> _renameFolder(Map<String, dynamic> f) async {
    final name = TextEditingController(text: f['name']?.toString() ?? '');
    final ok = await showFormSheet(context, square: true, title: 'Rename folder', builder: (_) => [
      sheetField(name, 'Folder name', CupertinoIcons.folder),
    ], onSubmit: () async {
      if (name.text.trim().isEmpty) return 'Name required';
      try { await widget.auth.apiPatch('/api/v1/manage/video-folders/${f['id']}', {'name': name.text.trim()}); return null; }
      on ApiException catch (e) { return e.message; }
    });
    if (ok == true) { _toast('Renamed'); _load(); }
  }

  Future<void> _deleteFolder(Map<String, dynamic> f) async {
    final yes = await showSquareConfirm(context,
        title: 'Delete folder',
        message: 'Delete “${f['name']}”? Its videos aren’t deleted — they move to Unfiled.',
        confirmLabel: 'Delete', destructive: true);
    if (!yes) return;
    try {
      await widget.auth.apiDelete('/api/v1/manage/video-folders/${f['id']}');
      // Its videos land in Unfiled, so follow them there rather than leaving
      // no chip selected.
      if (_folder == f['id'].toString()) _folder = '__none__';
      _toast('Folder deleted'); _load();
    } catch (_) { _toast('Could not delete'); }
  }

  // Move a video into a folder (or Unfiled).
  Future<void> _moveToFolder(String videoId) async {
    final items = <SquareMenuItem>[
      const SquareMenuItem('Unfiled (no folder)', value: '', icon: CupertinoIcons.tray),
      for (final f in _folders) SquareMenuItem(f['name']?.toString() ?? 'Folder', value: f['id'].toString(), icon: CupertinoIcons.folder_fill),
    ];
    final v = await showSquareMenu(context, title: 'Move to folder', items: items);
    if (v == null) return;
    try {
      await widget.auth.apiPost('/api/v1/manage/videos/$videoId/folder', {'folder_id': v});
      _toast('Moved'); _load();
    } catch (_) { _toast('Could not move'); }
  }

  // Square (1:1) video card for the grid.
  Widget _gridCard(Map<String, dynamic> v) {
    final p = Palette.of(context);
    final url = v['url']?.toString() ?? '';
    final title = v['title']?.toString() ?? 'Video';
    final status = v['status']?.toString() ?? 'ready';
    final ready = status == 'ready';
    final processing = status == 'processing';
    final statusColor = ready ? AppleColors.green : (processing ? AppleColors.orange : AppleColors.red);
    final statusText = ready ? 'HLS ready' : (processing ? 'Processing…' : 'Failed');
    return AppleCard(
      square: true,
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Thumbnail / play area fills the top of the square.
        Expanded(
          child: HoverTap(
            onTap: () => _play(url, title),
            child: Builder(builder: (_) {
              final thumb = v['thumb_url']?.toString() ?? '';
              return Container(
                decoration: BoxDecoration(color: p.accent.withOpacity(0.12)),
                alignment: Alignment.center,
                child: Stack(fit: StackFit.expand, alignment: Alignment.center, children: [
                  if (thumb.isNotEmpty)
                    Image.network(thumb, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox())
                  else if (!processing)
                    Center(child: Icon(CupertinoIcons.play_rectangle_fill, size: 44, color: p.accent)),
                  if (processing) const Center(child: CupertinoActivityIndicator(radius: 12)),
                  // Play affordance over a real thumbnail.
                  if (thumb.isNotEmpty && !processing)
                    const Center(child: Icon(CupertinoIcons.play_circle_fill, size: 40, color: Colors.white)),
                ]),
              );
            }),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(title, style: AppleTheme.body(context).copyWith(fontSize: 13.5, fontWeight: FontWeight.w600), maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 3),
            HoverTap(onTap: () => _showDetails(v), child: Text(_metaLine(v), style: AppleTheme.footnote(context), maxLines: 1, overflow: TextOverflow.ellipsis)),
            const SizedBox(height: 6),
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: statusColor.withOpacity(0.15)),
                child: Text(statusText, style: TextStyle(color: statusColor, fontSize: 9.5, fontWeight: FontWeight.w700)),
              ),
              const Spacer(),
              if (widget.onPick != null)
                HoverTap(
                  onTap: () => widget.onPick!(v['id']?.toString() ?? '', url, title),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: p.accent),
                    child: const Text('Use', style: TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700)),
                  ),
                )
              else ...[
                HoverTap(onTap: () { Clipboard.setData(ClipboardData(text: url)); _toast('URL copied'); }, child: Icon(CupertinoIcons.doc_on_doc, size: 16, color: p.secondary)),
                const SizedBox(width: 10),
                HoverTap(onTap: () => _moveToFolder(v['id'].toString()), child: Icon(CupertinoIcons.folder, size: 16, color: p.secondary)),
                const SizedBox(width: 10),
                HoverTap(onTap: () => _rename(v['id'].toString(), title), child: Icon(CupertinoIcons.pencil, size: 16, color: p.secondary)),
                const SizedBox(width: 10),
                HoverTap(onTap: () => _delete(v['id'].toString(), title), child: const Icon(CupertinoIcons.trash, size: 16, color: AppleColors.red)),
              ],
            ]),
          ]),
        ),
      ]),
    );
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
              onTap: () => _moveToFolder(v['id'].toString()),
              child: Icon(CupertinoIcons.folder, size: 20, color: p.secondary),
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

/// Folder action (Rename / Delete / New folder). Stateful purely so it can
/// highlight under the cursor — it deepens its tint and firms its border,
/// matching the compact buttons elsewhere in the admin.
class _FolderActionBtn extends StatefulWidget {
  const _FolderActionBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.color,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  @override
  State<_FolderActionBtn> createState() => _FolderActionBtnState();
}

class _FolderActionBtnState extends State<_FolderActionBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.color;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: c.withValues(alpha: _hover ? 0.22 : 0.10),
            borderRadius: BorderRadius.circular(kRadiusField),
            border: Border.all(color: c.withValues(alpha: _hover ? 1 : 0.4)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(widget.icon, size: 15, color: c),
            const SizedBox(width: 5),
            Text(widget.label,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c)),
          ]),
        ),
      ),
    );
  }
}
