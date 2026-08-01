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

/// The LMS admin look: orange-red accent, neutral surfaces, flatter depth.
/// Admin/LMS palette — a cool blue-grey ground with white cards floating on it.
/// The accent stays the ONROL orange; swap [accent]/[accentDark] for the teal
/// pair below if the brand ever moves.
class AdminColors {
  // Google-inspired enterprise scheme: a single blue primary (#1A73E8) for all
  // interactive emphasis — links, selected nav, primary buttons, focus.
  static const accent = Color(0xFF1A73E8);
  static const accentHover = Color(0xFF1765CC);
  static const accentDark = Color(0xFF8AB4F8);      // blue that reads on dark surfaces

  // Light theme surfaces.
  static const lightBg = Color(0xFFF8F9FA);        // app ground
  static const lightCard = Color(0xFFFFFFFF);      // surface
  static const lightCard2 = Color(0xFFF1F3F4);     // recessed inner boxes
  static const lightRowAlt = Color(0xFFFAFAFA);    // alternating table row
  static const lightLabel = Color(0xFF202124);     // primary text
  static const lightSecondary = Color(0xFF5F6368); // secondary text
  static const lightMuted = Color(0xFF9AA0A6);     // disabled / muted text
  static const lightSeparator = Color(0xFFDADCE0); // 1px borders

  // Status colours (communicate state, never decoration).
  static const secondaryAccent = Color(0xFF1A73E8); // (kept as alias for blue)
  static const danger = Color(0xFFD93025);
  static const success = Color(0xFF188038);
  static const warning = Color(0xFFF9AB00);
  // Legacy alias — some call sites still reference `lime`; map it to the blue
  // primary so nothing renders neon while those are migrated.
  static const lime = accent;

  static const darkBg = Color(0xFF0E151B);
  static const darkCard = Color(0xFF16202A);
  static const darkCard2 = Color(0xFF1C2833);
  static const darkLabel = Color(0xFFE6EDF3);
  static const darkSecondary = Color(0xFF8FA3B5);
  static const darkSeparator = Color(0xFF24313D);

  // The admin left nav. Deliberately one fixed set for both light and dark
  // themes — the panel reads as a constant frame around content that changes.
  // The ground is LIGHT, so the ink here is dark; these five move together or
  // the panel loses contrast.
  static const sideBg = Color(0xFFD9D9D9);      // panel ground
  static const sideCard = Color(0xFFF2F2F2);    // raised box within the panel
  static const sideBorder = Color(0xFF000000);      // hard black panel outline
  static const sideCardBorder = Color(0xFFB4B4B4);  // inner boxes stay softer
  static const sideInk = Color(0xFF16191D);     // nav labels
  static const sideMuted = Color(0xFF565B62);   // icons, section headers

  /// Pastel chip pairs (background, icon) for stat tiles — decorative only,
  /// never the accent. Mirrors the reference's purple/pink/orange/teal set.
  static const chipPurpleBg = Color(0xFFE9D5FF);
  static const chipPurpleFg = Color(0xFF9333EA);
  static const chipPinkBg = Color(0xFFFCE7F3);
  static const chipPinkFg = Color(0xFFDB2777);
  static const chipOrangeBg = Color(0xFFFFEDD5);
  static const chipOrangeFg = Color(0xFFEA580C);
  static const chipTealBg = Color(0xFFCCFBF1);
  static const chipTealFg = Color(0xFF0D9488);
}

/// Marks a subtree as the LMS admin skin. Student surfaces keep Apple tokens.
class AdminSkin extends InheritedWidget {
  const AdminSkin({super.key, required super.child});
  static bool on(BuildContext c) => c.getInheritedWidgetOfExactType<AdminSkin>() != null;
  @override
  bool updateShouldNotify(AdminSkin oldWidget) => false;
}

/// Per-theme palette resolved from BuildContext.
class Palette {
  Palette(this.context);
  final BuildContext context;
  bool get dark => Theme.of(context).brightness == Brightness.dark;
  bool get admin => AdminSkin.on(context);

  Color get bg => admin ? (dark ? AdminColors.darkBg : AdminColors.lightBg) : (dark ? AppleColors.darkBg : AppleColors.lightBg);
  Color get card => admin ? (dark ? AdminColors.darkCard : AdminColors.lightCard) : (dark ? AppleColors.darkCard : AppleColors.lightCard);
  Color get card2 => admin ? (dark ? AdminColors.darkCard2 : AdminColors.lightCard2) : (dark ? AppleColors.darkCard2 : const Color(0xFFF2F2F7));
  Color get label => admin ? (dark ? AdminColors.darkLabel : AdminColors.lightLabel) : (dark ? AppleColors.darkLabel : AppleColors.lightLabel);
  Color get secondary => admin ? (dark ? AdminColors.darkSecondary : AdminColors.lightSecondary) : (dark ? AppleColors.darkSecondary : AppleColors.lightSecondary);
  Color get separator => admin ? (dark ? AdminColors.darkSeparator : AdminColors.lightSeparator) : (dark ? AppleColors.darkSeparator : AppleColors.lightSeparator);
  Color get accent => admin ? (dark ? AdminColors.accentDark : AdminColors.accent) : (dark ? AppleColors.blueDark : AppleColors.blue);

  /// Claymorphism depth: a soft cool drop shadow + a light top-left highlight,
  /// giving surfaces a puffy, inflated "clay" look.
  List<BoxShadow> get clay => admin
      ? (dark
          ? [BoxShadow(color: Colors.black.withOpacity(0.55), offset: const Offset(0, 10), blurRadius: 30, spreadRadius: -16), BoxShadow(color: Colors.black.withOpacity(0.4), offset: const Offset(0, 1), blurRadius: 2)]
          : [BoxShadow(color: const Color(0xFF101C28).withOpacity(0.16), offset: const Offset(0, 8), blurRadius: 24, spreadRadius: -14), BoxShadow(color: const Color(0xFF101C28).withOpacity(0.06), offset: const Offset(0, 1), blurRadius: 2)])
      : (dark
          ? [
              BoxShadow(color: AppleColors.clayShadowDark.withOpacity(0.65), offset: const Offset(0, 14), blurRadius: 26, spreadRadius: -4),
              BoxShadow(color: AppleColors.clayHighlightDark.withOpacity(0.55), offset: const Offset(-6, -6), blurRadius: 14, spreadRadius: -8),
            ]
          : [
              BoxShadow(color: AppleColors.clayShadow.withOpacity(0.75), offset: const Offset(0, 14), blurRadius: 30, spreadRadius: -6),
              BoxShadow(color: AppleColors.clayHighlight.withOpacity(0.9), offset: const Offset(-8, -8), blurRadius: 18, spreadRadius: -10),
            ]);

  /// The one shadow style used across the admin: 0 12px 30px rgba(0,0,0,.06).
  /// A single consistent elevation — no competing shadow treatments.
  List<BoxShadow> get soft => dark
      ? [BoxShadow(color: Colors.black.withOpacity(0.38), offset: const Offset(0, 12), blurRadius: 30, spreadRadius: -8)]
      : [BoxShadow(color: Colors.black.withOpacity(0.06), offset: const Offset(0, 12), blurRadius: 30, spreadRadius: 0)];

  /// Hover elevation: 0 18px 40px rgba(0,0,0,.08).
  List<BoxShadow> get softHover => dark
      ? [BoxShadow(color: Colors.black.withOpacity(0.48), offset: const Offset(0, 18), blurRadius: 40, spreadRadius: -8)]
      : [BoxShadow(color: Colors.black.withOpacity(0.08), offset: const Offset(0, 18), blurRadius: 40, spreadRadius: 0)];

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

    final text = GoogleFonts.interTextTheme(
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
      GoogleFonts.inter(fontSize: 32, fontWeight: FontWeight.w800, letterSpacing: -0.6, color: Palette.of(c).label);
  static TextStyle title2(BuildContext c) =>
      GoogleFonts.inter(fontSize: 21, fontWeight: FontWeight.w700, letterSpacing: -0.3, color: Palette.of(c).label);
  static TextStyle headline(BuildContext c) =>
      GoogleFonts.inter(fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.2, color: Palette.of(c).label);
  static TextStyle body(BuildContext c) =>
      GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w400, color: Palette.of(c).label);
  static TextStyle subhead(BuildContext c) =>
      GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w400, color: Palette.of(c).secondary);
  static TextStyle footnote(BuildContext c) =>
      GoogleFonts.inter(fontSize: 12.5, fontWeight: FontWeight.w500, color: Palette.of(c).secondary);
}
