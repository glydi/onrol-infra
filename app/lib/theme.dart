import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Apple-ecosystem design tokens (iOS / macOS system colors + SF-style type).
class AppleColors {
  // System blue (the canonical Apple accent).
  static const blue = Color(0xFF007AFF);
  static const blueDark = Color(0xFF0A84FF);
  static const green = Color(0xFF34C759);
  static const orange = Color(0xFFFF9500);
  static const red = Color(0xFFFF3B30);
  static const purple = Color(0xFFAF52DE);
  static const teal = Color(0xFF5AC8FA);

  // Light — soft pastel "clay" background with white puffy surfaces.
  static const lightBg = Color(0xFFE8ECF6);
  static const lightCard = Color(0xFFFFFFFF);
  static const lightLabel = Color(0xFF2A2D3A);
  static const lightSecondary = Color(0xFF8A90A6);
  static const lightSeparator = Color(0x22384060);

  // Dark — deep slate background with raised clay surfaces.
  static const darkBg = Color(0xFF12141C);
  static const darkCard = Color(0xFF20232E);
  static const darkCard2 = Color(0xFF2A2E3C);
  static const darkLabel = Color(0xFFF2F3F8);
  static const darkSecondary = Color(0xFF9AA0B4);
  static const darkSeparator = Color(0x33606880);

  // Claymorphism shadow + highlight (soft puffy depth).
  static const clayShadow = Color(0xFFB4BCD0); // soft cool drop shadow (light)
  static const clayHighlight = Color(0xFFFFFFFF); // top-left highlight (light)
  static const clayShadowDark = Color(0xFF080A10);
  static const clayHighlightDark = Color(0xFF353A4A);
}

/// Per-theme palette resolved from BuildContext.
class Palette {
  Palette(this.context);
  final BuildContext context;
  bool get dark => Theme.of(context).brightness == Brightness.dark;

  Color get bg => dark ? AppleColors.darkBg : AppleColors.lightBg;
  Color get card => dark ? AppleColors.darkCard : AppleColors.lightCard;
  Color get card2 => dark ? AppleColors.darkCard2 : const Color(0xFFF2F2F7);
  Color get label => dark ? AppleColors.darkLabel : AppleColors.lightLabel;
  Color get secondary => dark ? AppleColors.darkSecondary : AppleColors.lightSecondary;
  Color get separator => dark ? AppleColors.darkSeparator : AppleColors.lightSeparator;
  Color get accent => dark ? AppleColors.blueDark : AppleColors.blue;

  /// Claymorphism depth: a soft cool drop shadow + a light top-left highlight,
  /// giving surfaces a puffy, inflated "clay" look.
  List<BoxShadow> get clay => dark
      ? [
          BoxShadow(color: AppleColors.clayShadowDark.withOpacity(0.65), offset: const Offset(0, 14), blurRadius: 26, spreadRadius: -4),
          BoxShadow(color: AppleColors.clayHighlightDark.withOpacity(0.55), offset: const Offset(-6, -6), blurRadius: 14, spreadRadius: -8),
        ]
      : [
          BoxShadow(color: AppleColors.clayShadow.withOpacity(0.75), offset: const Offset(0, 14), blurRadius: 30, spreadRadius: -6),
          BoxShadow(color: AppleColors.clayHighlight.withOpacity(0.9), offset: const Offset(-8, -8), blurRadius: 18, spreadRadius: -10),
        ];

  static Palette of(BuildContext c) => Palette(c);
}

class AppleTheme {
  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness b) {
    final dark = b == Brightness.dark;
    final bg = dark ? AppleColors.darkBg : AppleColors.lightBg;
    final label = dark ? AppleColors.darkLabel : AppleColors.lightLabel;
    final accent = dark ? AppleColors.blueDark : AppleColors.blue;

    final text = GoogleFonts.poppinsTextTheme(
      ThemeData(brightness: b).textTheme,
    ).apply(bodyColor: label, displayColor: label);

    return ThemeData(
      useMaterial3: true,
      brightness: b,
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: b,
      ).copyWith(primary: accent, surface: bg),
      textTheme: text,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
    );
  }

  // SF-style type ramp.
  static TextStyle largeTitle(BuildContext c) =>
      GoogleFonts.poppins(fontSize: 32, fontWeight: FontWeight.w800, letterSpacing: -0.6, color: Palette.of(c).label);
  static TextStyle title2(BuildContext c) =>
      GoogleFonts.poppins(fontSize: 21, fontWeight: FontWeight.w700, letterSpacing: -0.3, color: Palette.of(c).label);
  static TextStyle headline(BuildContext c) =>
      GoogleFonts.poppins(fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.2, color: Palette.of(c).label);
  static TextStyle body(BuildContext c) =>
      GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w400, color: Palette.of(c).label);
  static TextStyle subhead(BuildContext c) =>
      GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w400, color: Palette.of(c).secondary);
  static TextStyle footnote(BuildContext c) =>
      GoogleFonts.poppins(fontSize: 12.5, fontWeight: FontWeight.w500, color: Palette.of(c).secondary);
}
