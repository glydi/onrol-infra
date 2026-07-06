import 'dart:convert';
import 'dart:html' as html;

// Trigger a browser download of `content` as a file (used for the attendance
// CSV export from the live-host panel).
void downloadText(String filename, String content, {String mime = 'text/csv'}) {
  final bytes = utf8.encode(content);
  final blob = html.Blob(<Object>[bytes], mime);
  final url = html.Url.createObjectUrlFromBlob(blob);
  final a = html.AnchorElement(href: url)
    ..download = filename
    ..style.display = 'none';
  html.document.body?.append(a);
  a.click();
  a.remove();
  html.Url.revokeObjectUrl(url);
}
