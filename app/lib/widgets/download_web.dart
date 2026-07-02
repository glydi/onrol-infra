import 'dart:html' as html;

// Trigger a browser download of [bytes] as [filename] (web only).
void saveFileBytes(String filename, String mime, List<int> bytes) {
  final blob = html.Blob([bytes], mime.isEmpty ? 'application/octet-stream' : mime);
  final url = html.Url.createObjectUrlFromBlob(blob);
  final a = html.AnchorElement(href: url)..download = filename.isEmpty ? 'file' : filename;
  html.document.body?.append(a);
  a.click();
  a.remove();
  html.Url.revokeObjectUrl(url);
}
