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

// ============================================================================
// Design tokens — namespaced PRIMITIVE scales (the Dart mirror of a CSS
// `--space-*` / `--radius-*` / `--text-*` token architecture). Components
// compose these rather than hard-coding values, so a redesign is a token
// change. Calibrated to the Notion admin look.
// ============================================================================

/// 4px-baseline spacing scale. Use `Space.s4` etc. instead of literal gaps.
class Space {
  static const double s0 = 0;
  static const double s1 = 4;   // hairline
  static const double s2 = 8;   // tight
  static const double s3 = 12;  // small gap / list-item gap
  static const double s4 = 16;  // default / inside-card gap
  static const double s5 = 20;
  static const double s6 = 24;  // card padding / section gap
  static const double s8 = 32;  // major
  static const double s10 = 40;
  static const double s12 = 48; // large section
  static const double s16 = 64; // page spacing
}

/// Corner-radius scale (xs→full).
class Radii {
  static const double xs = 4;
  static const double sm = 6;
  static const double md = 8;
  static const double lg = 12;
  static const double xl = 16;
  static const double full = 999;
}

/// Font-size primitives (compose with [FontWeight] directly).
class TextSize {
  static const double xs = 12;
  static const double sm = 14;
  static const double md = 16;
  static const double lg = 18;
  static const double xl = 22;
  static const double xxl = 28;
}

/// Elevation scale. The admin is flat today (`none`); the higher steps exist so
/// a later decision to elevate e.g. dialogs is a one-token change, not a sweep.
class Shadows {
  static const List<BoxShadow> none = [];
  static final List<BoxShadow> xs = [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 2, offset: const Offset(0, 1))];
  static final List<BoxShadow> sm = [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 6, offset: const Offset(0, 2))];
  static final List<BoxShadow> md = [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 24, offset: const Offset(0, 8))];
}

/// Component-token layer — maps component sizing to the primitive scales in one
/// place, so redesigning a component is a token edit, not a hunt through code.
class Tokens {
  // Layout
  static const double sidebarWidth = 240;
  static const double topbarHeight = 48;
  static const double contentMaxWidth = 1280;
  static const double contentPadX = Space.s8;   // 32 (wide screens)
  static const double contentPadY = Space.s5;   // 20
  // Cards
  static const double cardPadding = Space.s6;   // 24
  static const double cardGap = Space.s4;       // 16
  static const double listItemGap = Space.s3;   // 12
  // Controls
  static const double buttonHeight = 34;
  static const double buttonPadX = 14;
  static const double inputHeight = 38;
  static const double inputPadX = Space.s3;      // 12
  static const double navItemHeight = 34;
  static const double iconSize = 18;
  static const double iconButton = 36;
  static const double avatar = 36;
}

/// The LMS admin palette — Notion-inspired (warm surfaces, warm dark ink,
/// minimal colour). Semantic names, refined values. Light-mode only.
class AdminColors {
  // Brand / primary (used sparingly — links, selected, the one CTA).
  static const accent = Color(0xFF2383E2);          // --color-primary
  static const accentHover = Color(0xFF1D73C8);     // --color-primary-hover
  static const primarySoft = Color(0xFFEEF6FF);     // --color-primary-soft (tint)
  static const accentDark = Color(0xFF529CE8);      // blue that reads on dark surfaces

  // Surfaces (light-mode only).
  static const lightBg = Color(0xFFFFFFFF);        // --color-bg
  static const lightCard = Color(0xFFFFFFFF);      // --color-surface
  static const surfaceMuted = Color(0xFFF8F8F7);   // --color-surface-muted
  static const lightCard2 = Color(0xFFF5F5F3);     // --color-surface-sunk (recessed)
  static const lightRowAlt = Color(0xFFF8F8F7);    // alternating table row
  static const lightLabel = Color(0xFF37352F);     // --color-text
  static const lightSecondary = Color(0xFF6F6E69); // --color-text-secondary
  static const lightMuted = Color(0xFF9B9A97);     // --color-text-muted
  static const textDisabled = Color(0xFFB8B7B4);   // --color-text-disabled
  static const lightSeparator = Color(0xFFE5E5E3); // --color-border

  // State neutrals.
  static const sidebarBg = Color(0xFFFBFBFA);      // warm off-white nav panel
  static const hoverBg = Color(0xFFEFEFEE);        // --color-hover
  static const selectedBg = Color(0xFFE8E8E6);     // --color-selected

  // Status colours (communicate state, never decoration).
  static const secondaryAccent = accent; // (kept as alias for blue)
  static const danger = Color(0xFFE03E3E);
  static const success = Color(0xFF0F7B6C);
  static const warning = Color(0xFFD9730D);
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
  bool get admin => AdminSkin.on(context);
  // Admin is light-mode only — it never follows a dark OS/app theme, so every
  // `p.dark ? … : …` in an admin surface resolves to the light token.
  bool get dark => admin ? false : Theme.of(context).brightness == Brightness.dark;

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
