import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart' hide Text;
import 'package:flutter/material.dart' hide Text;
import 'package:onrol_app/widgets/upper_text.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import 'ui.dart';

/// Opens the shared **image library** as a picker and returns the chosen image's
/// public URL (or null if cancelled). The admin can upload a new image (stored
/// in R2 via `/manage/images`) or pick any previously uploaded one. Use this
/// everywhere an image is needed — course covers, live thumbnails/banners,
/// Explore tiles — so every image lives in one reusable library.
Future<String?> pickLibraryImage(BuildContext context, AuthService auth) {
  final sq = SquareScope.of(context);
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(0.45),
    builder: (ctx) => SquareScope(square: sq, child: _ImageLibrarySheet(auth: auth)),
  );
}

class _ImageLibrarySheet extends StatefulWidget {
  const _ImageLibrarySheet({required this.auth});
  final AuthService auth;
  @override
  State<_ImageLibrarySheet> createState() => _ImageLibrarySheetState();
}

class _ImageLibrarySheetState extends State<_ImageLibrarySheet> {
  List<Map<String, dynamic>> _images = [];
  bool _loading = true;
  bool _busy = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await widget.auth.apiGet('/api/v1/manage/images');
      final list = (ApiClient.decode(r)['images'] as List?) ?? [];
      _images = list.map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      _err = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _upload() async {
    try {
      final res = await FilePicker.platform.pickFiles(withData: true);
      if (res == null || res.files.isEmpty) return;
      final f = res.files.first;
      final bytes = f.bytes;
      if (bytes == null || bytes.isEmpty) return;
      setState(() { _busy = true; _err = null; });
      final r = await widget.auth.apiUpload('/api/v1/manage/images/upload',
          bytes: bytes, filename: f.name, fields: {'title': f.name});
      final data = ApiClient.decode(r);
      final url = data['url']?.toString();
      if (url != null && url.isNotEmpty) {
        // Upload-and-use: hand the new image straight back to the caller.
        if (mounted) Navigator.pop(context, url);
        return;
      }
      _err = 'Upload failed';
    } catch (e) {
      _err = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final screenH = MediaQuery.of(context).size.height;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Align(
        alignment: Alignment.center,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 760, maxHeight: screenH * 0.85),
          child: Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: p.card, borderRadius: adminRadius(p, kRadiusSheet)),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: Text('Image library', style: AppleTheme.title2(context))),
                SmallActionButton(label: 'Upload', icon: CupertinoIcons.cloud_upload, onPressed: _busy ? null : _upload),
              ]),
              const SizedBox(height: 6),
              Text('Pick an image to use, or upload a new one.', style: AppleTheme.footnote(context)),
              const SizedBox(height: 16),
              if (_err != null) ...[
                Text(_err!, style: AppleTheme.footnote(context).copyWith(color: AppleColors.red)),
                const SizedBox(height: 10),
              ],
              Flexible(
                child: _loading || _busy
                    ? const Padding(padding: EdgeInsets.symmetric(vertical: 40), child: Center(child: CupertinoActivityIndicator()))
                    : _images.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 40),
                            child: Center(child: Text('No images yet — upload one to get started.', style: AppleTheme.footnote(context))))
                        : LayoutBuilder(builder: (context, c) {
                            const gap = 12.0;
                            final cols = c.maxWidth >= 620 ? 4 : (c.maxWidth >= 420 ? 3 : 2);
                            final tile = (c.maxWidth - gap * (cols - 1)) / cols;
                            return SingleChildScrollView(
                              child: Wrap(spacing: gap, runSpacing: gap, children: [
                                for (final img in _images)
                                  SizedBox(
                                    width: tile,
                                    height: tile,
                                    child: _tile(img['url']?.toString() ?? '', img['title']?.toString() ?? ''),
                                  ),
                              ]),
                            );
                          }),
              ),
              const SizedBox(height: 14),
              TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel', style: TextStyle(color: p.secondary))),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _tile(String url, String title) {
    final p = Palette.of(context);
    return HoverTap(
      onTap: () => Navigator.pop(context, url),
      child: ClipRRect(
        borderRadius: adminRadius(p, kRadiusField),
        child: Container(
          decoration: BoxDecoration(color: p.card2, border: Border.all(color: p.separator), borderRadius: adminRadius(p, kRadiusField)),
          child: url.isEmpty
              ? const Icon(CupertinoIcons.photo)
              : Image.network(url, fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const Center(child: Icon(CupertinoIcons.photo))),
        ),
      ),
    );
  }
}
