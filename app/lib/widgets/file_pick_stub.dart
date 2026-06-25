import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Mobile/desktop video picker (uses file_picker). Web uses file_pick_web.dart.
/// Reads the file in slices straight from disk (withData:false → we keep the
/// path, not the bytes) so multi-GB uploads never load the whole file into RAM.
Future<({String name, int size, Future<Uint8List> Function(int start, int end) read})?> pickVideoFile() async {
  final res = await FilePicker.platform.pickFiles(type: FileType.video, withData: false);
  if (res == null || res.files.isEmpty) return null;
  final f = res.files.first;
  final path = f.path;
  if (path == null) return null;
  final file = File(path);
  final size = await file.length();

  Future<Uint8List> read(int start, int end) async {
    final raf = await file.open();
    try {
      await raf.setPosition(start);
      return await raf.read(end - start);
    } finally {
      await raf.close();
    }
  }

  return (name: f.name, size: size, read: read);
}
