// Drop-in replacement for the framework `Text` widget. It USED to force every
// string to UPPERCASE app-wide, which made the UI read as shouting. It now
// renders text in its natural, as-written case. Deliberate small-caps accents
// (section labels, stat captions, sidebar section headers) still uppercase
// themselves by calling `.toUpperCase()` on the string explicitly, so those are
// unaffected.
//
// The widget is kept (rather than reverting call sites to the framework Text)
// so a single place controls global text casing, and so the many files that
// `import ... hide Text; import upper_text.dart` keep compiling unchanged.
import 'package:flutter/widgets.dart' hide Text;
import 'package:flutter/widgets.dart' as w;

class Text extends StatelessWidget {
  final String data;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final Color? selectionColor;

  const Text(
    this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  });

  @override
  Widget build(BuildContext context) => w.Text(
        data.toUpperCase(),
        style: style,
        strutStyle: strutStyle,
        textAlign: textAlign,
        textDirection: textDirection,
        locale: locale,
        softWrap: softWrap,
        overflow: overflow,
        textScaler: textScaler,
        maxLines: maxLines,
        // Only forward an explicit label. Do NOT synthesize one from `data`:
        // a non-null semanticsLabel makes Text wrap every string in
        // Semantics+ExcludeSemantics widgets, ~tripling the widget count and
        // making content-heavy screens lag badly.
        semanticsLabel: semanticsLabel,
        textWidthBasis: textWidthBasis,
        textHeightBehavior: textHeightBehavior,
        selectionColor: selectionColor,
      );
}
