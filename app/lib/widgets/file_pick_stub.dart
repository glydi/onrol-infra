import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Mobile/desktop video picker (uses file_picker). Web uses file_pick_web.dart.
Future<({Uint8List bytes, String name})?> pickVideoFile() async {
  final res = await FilePicker.platform.pickFiles(type: FileType.video, withData: true);
  if (res == null || res.files.isEmpty) return null;
  final f = res.files.first;
  if (f.bytes == null) return null;
  return (bytes: f.bytes!, name: f.name);
}
