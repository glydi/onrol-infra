import 'dart:html' as html;

// Shows the unread-notification count as a "(N)" prefix on the browser tab
// title, so a student sees pending notifications even when the tab isn't
// focused — e.g. "(3) ONROL Learn". Passing 0 restores the plain title.
//
// The base title is captured from the page's <title> on first use and any
// existing "(N)" prefix is stripped, so repeated calls never stack.
String? _baseTitle;

void setUnreadBadge(int count) {
  final current = html.document.title;
  _baseTitle ??= _stripBadge(current);
  final base = (_baseTitle == null || _baseTitle!.isEmpty) ? 'ONROL Learn' : _baseTitle!;
  final label = count > 99 ? '99+' : '$count';
  final next = count > 0 ? '($label) $base' : base;
  if (current != next) html.document.title = next;
}

// Drop a leading "(N)" / "(99+)" badge so we don't prefix a prefix.
String _stripBadge(String t) {
  final m = RegExp(r'^\(\d+\+?\)\s*').firstMatch(t);
  return m == null ? t : t.substring(m.end);
}
