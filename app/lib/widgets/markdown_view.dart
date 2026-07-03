import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Renders a Markdown subset — headings (#, ##, ###), **bold**, *italic*,
/// `inline code`, bulleted / numbered lists, `- [ ]` to-do checkboxes, `>`
/// quotes, fenced ``` code blocks, and `---` dividers — as clean, Notion-like
/// blocks. Colours are passed in so it works on any palette (student app, admin
/// console, etc.). [onToggle] fires with a source line index when a to-do
/// checkbox is tapped (omit it to render the checkboxes read-only).
class MarkdownView extends StatelessWidget {
  const MarkdownView({
    super.key,
    required this.text,
    required this.textColor,
    required this.mutedColor,
    required this.accent,
    required this.borderColor,
    this.dark = false,
    this.baseFontSize = 15.5,
    this.onToggle,
    this.emptyLabel = 'Nothing here yet.',
  });

  final String text;
  final Color textColor;
  final Color mutedColor;
  final Color accent;
  final Color borderColor;
  final bool dark;
  final double baseFontSize;
  final void Function(int lineIndex)? onToggle;
  final String emptyLabel;

  static final _todoRe = RegExp(r'^\s*[-*]\s+\[( |x|X)\]\s?(.*)$');
  static final _bulletRe = RegExp(r'^\s*[-*]\s+(.*)$');
  static final _numRe = RegExp(r'^\s*(\d+)\.\s+(.*)$');
  static final _inlineRe = RegExp(r'(\*\*(.+?)\*\*|\*(.+?)\*|`([^`]+?)`)');

  List<InlineSpan> _spans(String s, TextStyle base) {
    final out = <InlineSpan>[];
    var idx = 0;
    for (final m in _inlineRe.allMatches(s)) {
      if (m.start > idx) out.add(TextSpan(text: s.substring(idx, m.start), style: base));
      if (m.group(2) != null) {
        out.add(TextSpan(text: m.group(2), style: base.copyWith(fontWeight: FontWeight.w800)));
      } else if (m.group(3) != null) {
        out.add(TextSpan(text: m.group(3), style: base.copyWith(fontStyle: FontStyle.italic)));
      } else if (m.group(4) != null) {
        out.add(TextSpan(text: m.group(4), style: base.copyWith(fontFamily: 'monospace', color: textColor, backgroundColor: accent.withOpacity(0.12))));
      }
      idx = m.end;
    }
    if (idx < s.length) out.add(TextSpan(text: s.substring(idx), style: base));
    return out;
  }

  Widget _rich(String s, TextStyle base, TextScaler ts) => RichText(textScaler: ts, text: TextSpan(children: _spans(s, base)));

  @override
  Widget build(BuildContext context) {
    final ts = MediaQuery.textScalerOf(context); // so the material text respects the font-size setting
    final base = GoogleFonts.inter(fontSize: baseFontSize, color: textColor, height: 1.65);
    final lines = text.split('\n');
    final blocks = <Widget>[];
    var inCode = false;
    final codeBuf = <String>[];

    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final t = raw.trim();

      if (t.startsWith('```')) {
        if (inCode) {
          blocks.add(_code(codeBuf.join('\n')));
          codeBuf.clear();
          inCode = false;
        } else {
          inCode = true;
        }
        continue;
      }
      if (inCode) {
        codeBuf.add(raw);
        continue;
      }
      if (t == '---' || t == '***' || t == '___') {
        blocks.add(Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Container(height: 1, color: borderColor)));
        continue;
      }
      if (t.isEmpty) {
        blocks.add(const SizedBox(height: 9));
        continue;
      }
      if (t.startsWith('### ')) {
        blocks.add(_pad(_rich(t.substring(4), GoogleFonts.inter(fontSize: 17, fontWeight: FontWeight.w700, color: textColor, height: 1.3), ts), top: 8));
        continue;
      }
      if (t.startsWith('## ')) {
        blocks.add(_pad(_rich(t.substring(3), GoogleFonts.inter(fontSize: 21, fontWeight: FontWeight.w800, color: textColor, height: 1.3), ts), top: 10));
        continue;
      }
      if (t.startsWith('# ')) {
        blocks.add(_pad(_rich(t.substring(2), GoogleFonts.inter(fontSize: 26, fontWeight: FontWeight.w800, color: textColor, height: 1.25), ts), top: 12));
        continue;
      }
      final todo = _todoRe.firstMatch(raw);
      if (todo != null) {
        final checked = todo.group(1)!.toLowerCase() == 'x';
        final content = todo.group(2) ?? '';
        final li = i;
        blocks.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onToggle == null ? null : () => onToggle!(li),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 2, right: 9),
                child: Container(
                  width: 18, height: 18, alignment: Alignment.center,
                  decoration: BoxDecoration(color: checked ? accent : Colors.transparent, border: Border.all(color: checked ? accent : mutedColor, width: 1.4)),
                  child: checked ? const Icon(CupertinoIcons.checkmark, size: 12, color: Colors.white) : null,
                ),
              ),
              Expanded(child: _rich(content, base.copyWith(color: checked ? mutedColor : textColor, decoration: checked ? TextDecoration.lineThrough : null), ts)),
            ]),
          ),
        ));
        continue;
      }
      final bullet = _bulletRe.firstMatch(raw);
      if (bullet != null) {
        blocks.add(_listItem('•  ', bullet.group(1) ?? '', base, ts));
        continue;
      }
      final num = _numRe.firstMatch(raw);
      if (num != null) {
        blocks.add(_listItem('${num.group(1)}.  ', num.group(2) ?? '', base, ts));
        continue;
      }
      if (t.startsWith('> ')) {
        blocks.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
            decoration: BoxDecoration(border: Border(left: BorderSide(color: accent, width: 3))),
            child: _rich(t.substring(2), base.copyWith(color: mutedColor, fontStyle: FontStyle.italic), ts),
          ),
        ));
        continue;
      }
      blocks.add(_pad(_rich(t, base, ts), top: 2));
    }
    if (inCode && codeBuf.isNotEmpty) blocks.add(_code(codeBuf.join('\n')));
    if (blocks.isEmpty) {
      blocks.add(Text(emptyLabel, style: base.copyWith(color: mutedColor)));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: blocks);
  }

  Widget _pad(Widget child, {double top = 0}) => Padding(padding: EdgeInsets.only(top: top, bottom: 2), child: child);

  Widget _listItem(String marker, String content, TextStyle base, TextScaler ts) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(right: 2), child: Text(marker, style: base.copyWith(fontWeight: FontWeight.w700))),
          Expanded(child: _rich(content, base, ts)),
        ]),
      );

  Widget _code(String s) => Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: dark ? Colors.white.withOpacity(0.05) : const Color(0xFFF3F3F5), border: Border.all(color: borderColor)),
        child: Text(s, style: GoogleFonts.robotoMono(fontSize: 13, color: textColor, height: 1.45)),
      );
}
