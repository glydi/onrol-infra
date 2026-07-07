// Drop-in replacement for the framework `Text` widget that renders its data in
// UPPERCASE. The student app is uppercase throughout (to match the staff
// console); only text the user *types* stays true-case — and TextField/
// TextFormField are untouched by this, so typed input keeps its real case.
//
// Usage: a file opts in with
//   import 'package:flutter/material.dart' hide Text;
//   import 'package:onrol_app/widgets/upper_text.dart';
// Every existing `Text(...)` / `const Text(...)` call site then renders upper
// case with no other change. Code/markdown bodies (markdown_view.dart) and
// SelectableText/RichText deliberately keep their own casing.
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
        semanticsLabel: semanticsLabel ?? data,
        textWidthBasis: textWidthBasis,
        textHeightBehavior: textHeightBehavior,
        selectionColor: selectionColor,
      );
}
