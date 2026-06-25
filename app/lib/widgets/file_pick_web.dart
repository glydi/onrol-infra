import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

/// Web video picker via a native <input type=file>. Returns the file's name and
/// size plus a [read] callback that loads just one slice at a time — we never
/// hold the whole file in memory. Reading a multi-GB file into a single
/// Uint8List (the old behaviour) crashes the browser tab; slicing fixes that.
Future<({String name, int size, Future<Uint8List> Function(int start, int end) read})?> pickVideoFile() async {
  final input = html.FileUploadInputElement()
    ..accept = 'video/*'
    ..multiple = false;
  input.click();
  await input.onChange.first;
  final files = input.files;
  if (files == null || files.isEmpty) return null;
  final file = files.first;

  Future<Uint8List> read(int start, int end) async {
    final blob = file.slice(start, end);
    final reader = html.FileReader();
    reader.readAsArrayBuffer(blob);
    await reader.onLoad.first;
    final result = reader.result;
    return result is Uint8List ? result : Uint8List.fromList(List<int>.from(result as Iterable));
  }

  return (name: file.name, size: file.size, read: read);
}
