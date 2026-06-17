import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

/// Web video picker via a native <input type=file>. Reliable across browsers —
/// avoids the file_picker web plugin entirely.
Future<({Uint8List bytes, String name})?> pickVideoFile() async {
  final input = html.FileUploadInputElement()
    ..accept = 'video/*'
    ..multiple = false;
  input.click();
  await input.onChange.first;
  final files = input.files;
  if (files == null || files.isEmpty) return null;
  final file = files.first;
  final reader = html.FileReader();
  reader.readAsArrayBuffer(file);
  await reader.onLoad.first;
  final result = reader.result;
  final bytes = result is Uint8List ? result : Uint8List.fromList(List<int>.from(result as Iterable));
  return (bytes: bytes, name: file.name);
}
