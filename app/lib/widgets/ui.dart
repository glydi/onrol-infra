import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import '../theme_controller.dart';

/// A frosted, translucent top bar (iOS large-title style).
class GlassHeader extends StatelessWidget implements PreferredSizeWidget {
  const GlassHeader({super.key, required this.title, this.trailing, this.leading});
  final String title;
  final Widget? trailing;
  final Widget? leading;

  @override
  Size get preferredSize => const Size.fromHeight(52);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
          decoration: BoxDecoration(
            color: p.bg.withOpacity(0.72),
            border: Border(bottom: BorderSide(color: p.separator, width: 0.5)),
          ),
          child: SizedBox(
            height: 52,
            child: Row(
              children: [
                if (leading != null) leading! else const SizedBox(width: 16),
                Expanded(
                  child: Text(title,
                      style: AppleTheme.headline(context),
                      textAlign: TextAlign.center),
                ),
                if (trailing != null) trailing! else const SizedBox(width: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// White (or elevated) rounded card — the iOS grouped-content surface.
class AppleCard extends StatefulWidget {
  const AppleCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.onTap, this.square = false});
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final bool square; // admin/LMS panels use squared (radius 0) corners

  @override
  State<AppleCard> createState() => _AppleCardState();
}

class _AppleCardState extends State<AppleCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final interactive = widget.onTap != null;
    final hovered = interactive && _hover;
    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      width: double.infinity,
      padding: widget.padding,
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.zero,
        border: Border.all(color: hovered ? p.accent : p.separator),
        boxShadow: hovered
            ? [BoxShadow(color: Colors.black.withOpacity(p.dark ? 0.32 : 0.08), blurRadius: 12, offset: const Offset(0, 4))]
            : null,
      ),
      child: widget.child,
    );
    if (!interactive) return card;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(onTap: widget.onTap, behavior: HitTestBehavior.opaque, child: card),
    );
  }
}

/// Wraps a small tappable element (chip, icon, row) with a pointer cursor and a
/// subtle hover fade — for web ease-of-use on non-button controls.
class HoverTap extends StatefulWidget {
  const HoverTap({super.key, required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;

  @override
  State<HoverTap> createState() => _HoverTapState();
}

class _HoverTapState extends State<HoverTap> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: _hover ? 0.6 : 1.0,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Full-width filled blue CTA with a press-scale animation.
class PrimaryButton extends StatefulWidget {
  const PrimaryButton({super.key, required this.label, required this.onPressed, this.busy = false, this.icon, this.square = false});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final IconData? icon;
  final bool square; // admin panels use squared corners (no round buttons)

  @override
  State<PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<PrimaryButton> {
  double _scale = 1;
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final enabled = widget.onPressed != null && !widget.busy;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _scale = 0.97) : null,
      onTapUp: enabled ? (_) => setState(() => _scale = 1) : null,
      onTapCancel: enabled ? () => setState(() => _scale = 1) : null,
      onTap: enabled ? widget.onPressed : null,
      child: AnimatedScale(
        scale: _scale * (enabled && _hover ? 1.015 : 1.0),
        duration: const Duration(milliseconds: 90),
        child: Container(
          height: widget.square ? 46 : 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            // Admin (square): flat solid fill — sharp & standard. Else: gradient CTA.
            color: widget.square ? (enabled ? p.accent : p.secondary.withOpacity(0.35)) : null,
            gradient: widget.square
                ? null
                : LinearGradient(
                    colors: enabled
                        ? [p.accent, p.accent.withOpacity(0.82)]
                        : [p.secondary.withOpacity(0.4), p.secondary.withOpacity(0.4)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
            // Compact, Coursera-style: small radius, no heavy glow.
            borderRadius: BorderRadius.zero,
            boxShadow: (!widget.square && enabled)
                ? [BoxShadow(color: p.accent.withOpacity(0.20), offset: const Offset(0, 3), blurRadius: 8, spreadRadius: -2)]
                : null,
          ),
          child: widget.busy
              ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.icon != null) ...[Icon(widget.icon, color: Colors.white, size: 18), const SizedBox(width: 7)],
                    Text(widget.label,
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                  ],
                ),
        ),
      ),
    ));
  }
}

/// One row in a [showSquareMenu].
class SquareMenuItem {
  const SquareMenuItem(this.label, {this.value, this.icon, this.destructive = false});
  final String label;
  final Object? value; // returned on tap; falls back to [label]
  final IconData? icon;
  final bool destructive;
}

/// A plain squared popup menu (not an iOS action sheet): a centered panel with a
/// title and a list of tappable options. Returns the chosen item's value (or its
/// label), or null if dismissed.
Future<Object?> showSquareMenu(BuildContext context, {String? title, required List<SquareMenuItem> items}) {
  return showDialog<Object?>(
    context: context,
    barrierColor: Colors.black.withOpacity(0.4),
    builder: (ctx) {
      final p = Palette.of(ctx);
      return Dialog(
        backgroundColor: p.card,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
                child: Text(title, style: AppleTheme.footnote(ctx)),
              ),
            ...items.map((it) => HoverTap(
                  onTap: () => Navigator.pop(ctx, it.value ?? it.label),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                    decoration: BoxDecoration(border: Border(top: BorderSide(color: p.separator))),
                    child: Row(children: [
                      if (it.icon != null) ...[Icon(it.icon, size: 18, color: it.destructive ? AppleColors.red : p.label), const SizedBox(width: 12)],
                      Expanded(child: Text(it.label, style: AppleTheme.body(ctx).copyWith(color: it.destructive ? AppleColors.red : p.label))),
                    ]),
                  ),
                )),
          ]),
        ),
      );
    },
  );
}

/// A plain squared confirm dialog (not an iOS alert). Returns true if confirmed.
Future<bool> showSquareConfirm(BuildContext context, {required String title, required String message, String confirmLabel = 'Confirm', bool destructive = false}) async {
  final yes = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black.withOpacity(0.4),
    builder: (ctx) {
      final p = Palette.of(ctx);
      return Dialog(
        backgroundColor: p.card,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(title, style: AppleTheme.title2(ctx)),
              const SizedBox(height: 8),
              Text(message, style: AppleTheme.footnote(ctx)),
              const SizedBox(height: 20),
              Row(children: [
                Expanded(child: HoverTap(
                  onTap: () => Navigator.pop(ctx, false),
                  child: Container(
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(border: Border.all(color: p.separator)),
                    child: Text('Cancel', style: AppleTheme.body(ctx)),
                  ),
                )),
                const SizedBox(width: 10),
                Expanded(child: HoverTap(
                  onTap: () => Navigator.pop(ctx, true),
                  child: Container(
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: destructive ? AppleColors.red : p.accent),
                    child: Text(confirmLabel, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  ),
                )),
              ]),
            ]),
          ),
        ),
      );
    },
  );
  return yes ?? false;
}

/// iOS grouped text field. When [obscure] is set it shows a reveal (eye) toggle.
class AppleField extends StatefulWidget {
  const AppleField({super.key, required this.controller, required this.hint, this.icon, this.obscure = false, this.keyboard, this.autofillHints});
  final TextEditingController controller;
  final String hint;
  final IconData? icon;
  final bool obscure;
  final TextInputType? keyboard;
  final List<String>? autofillHints; // lets browsers / password managers offer to save & fill

  @override
  State<AppleField> createState() => _AppleFieldState();
}

class _AppleFieldState extends State<AppleField> {
  late bool _hidden = widget.obscure;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Row(
      children: [
        if (widget.icon != null) ...[Icon(widget.icon, size: 19, color: p.secondary), const SizedBox(width: 12)],
        Expanded(
          child: TextField(
            controller: widget.controller,
            obscureText: _hidden,
            keyboardType: widget.keyboard,
            autofillHints: widget.autofillHints,
            style: AppleTheme.body(context),
            cursorColor: p.accent,
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: widget.hint,
              hintStyle: AppleTheme.body(context).copyWith(color: p.secondary),
            ),
          ),
        ),
        if (widget.obscure)
          GestureDetector(
            onTap: () => setState(() => _hidden = !_hidden),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Icon(_hidden ? CupertinoIcons.eye_slash : CupertinoIcons.eye_fill, size: 19, color: p.secondary),
            ),
          ),
      ],
    );
  }
}

/// Light / Dark / System theme switcher (persists the choice).
class ThemeToggle extends StatelessWidget {
  const ThemeToggle({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, mode, _) {
        final idx = mode == ThemeMode.light ? 0 : (mode == ThemeMode.dark ? 1 : 2);
        return AppleSegmented(
          labels: const ['Light', 'Dark', 'System'],
          selected: idx,
          onChanged: (i) => setTheme(i == 0 ? ThemeMode.light : (i == 1 ? ThemeMode.dark : ThemeMode.system)),
        );
      },
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
      child: Row(
        children: [
          Text(title, style: AppleTheme.title2(context)),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Thin rounded progress bar.
class AppleProgress extends StatelessWidget {
  const AppleProgress({super.key, required this.value, this.color});
  final double value; // 0..1
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.zero,
      child: LinearProgressIndicator(
        value: value.clamp(0, 1),
        minHeight: 7,
        backgroundColor: p.dark ? AppleColors.darkCard2 : const Color(0xFFE5E5EA),
        valueColor: AlwaysStoppedAnimation(color ?? p.accent),
      ),
    );
  }
}

/// Circular initials avatar with a soft gradient.
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, this.size = 40});
  final String name;
  final double size;
  @override
  Widget build(BuildContext context) {
    final initials = name.trim().isEmpty
        ? '?'
        : name.trim().split(RegExp(r'\s+')).map((w) => w[0]).take(2).join().toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: [AppleColors.blue, AppleColors.purple], begin: Alignment.topLeft, end: Alignment.bottomRight),
      ),
      child: Text(initials, style: TextStyle(color: Colors.white, fontSize: size * 0.38, fontWeight: FontWeight.w700)),
    );
  }
}

/// Small stat tile (Enrolled / Completed / Certificates).
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.value, required this.label, required this.icon, required this.color});
  final String value;
  final String label;
  final IconData icon;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return AppleCard(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 10),
          Text(value, style: GoogleFontsInter(p.label, 24, FontWeight.w800)),
          Text(label, style: AppleTheme.footnote(context)),
        ],
      ),
    );
  }
}

// Small helper to avoid importing google_fonts everywhere.
TextStyle GoogleFontsInter(Color color, double size, FontWeight weight) =>
    TextStyle(color: color, fontSize: size, fontWeight: weight, letterSpacing: -0.3);

/// Checkerboard matrix layout — features (tiles) and white space alternate like:
///   1 0 1 0
///   0 1 0 1
///   1 0 1 0
/// Columns adapt to width (4 on desktop, 2 on phones); the empty cells are kept.
Widget checkerboardTiles(BuildContext context, List<Widget> tiles, {double gap = 14}) {
  final w = MediaQuery.of(context).size.width;
  final actualCols = w >= 1000 ? 4 : 2; // 4-wide matrix on desktop, 2 on phones
  final rows = <Widget>[];
  int i = 0, r = 0;
  while (i < tiles.length) {
    final start = r.isEven ? 0 : 1; // even rows fill cols 0,2,…; odd rows 1,3,…
    final cells = List<Widget?>.filled(actualCols, null);
    for (int c = start; c < actualCols; c += 2) {
      if (i < tiles.length) {
        cells[c] = tiles[i];
        i++;
      }
    }
    rows.add(Padding(
      padding: EdgeInsets.only(bottom: gap),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int c = 0; c < actualCols; c++) ...[
            if (c > 0) SizedBox(width: gap),
            Expanded(child: cells[c] ?? const SizedBox.shrink()),
          ],
        ],
      ),
    ));
    r++;
  }
  return Column(children: rows);
}

/// iOS segmented control. Pass labels + selected index.
class AppleSegmented extends StatelessWidget {
  const AppleSegmented({super.key, required this.labels, required this.selected, required this.onChanged, this.square = false});
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onChanged;
  final bool square; // admin/LMS panels use squared (radius 0) corners

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.dark ? AppleColors.darkCard2 : const Color(0xFFE9E9EB),
        borderRadius: BorderRadius.zero,
      ),
      child: Row(
        children: List.generate(labels.length, (i) {
          final on = i == selected;
          return Expanded(
            child: GestureDetector(
              onTap: () => onChanged(i),
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: on ? p.card : Colors.transparent,
                  borderRadius: BorderRadius.zero,
                  boxShadow: on && !p.dark
                      ? [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 6, offset: const Offset(0, 2))]
                      : null,
                ),
                child: Text(labels[i],
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                        color: on ? p.label : p.secondary)),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ---- shared form-sheet helpers (used by console + CRM) ---------------------

/// Marks a subtree (e.g. the LMS admin console) to render with squared corners.
/// Shared widgets below read this, so the student app / CRM stay rounded.
class SquareScope extends InheritedWidget {
  const SquareScope({super.key, this.square = true, required super.child});
  final bool square;
  static bool of(BuildContext c) => c.dependOnInheritedWidgetOfExactType<SquareScope>()?.square ?? false;
  @override
  bool updateShouldNotify(SquareScope old) => square != old.square;
}

Widget sheetField(TextEditingController c, String hint, IconData icon, {TextInputType? keyboard, bool square = false, bool obscure = false}) {
  return Builder(builder: (context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(color: p.card2, borderRadius: BorderRadius.zero),
      child: AppleField(controller: c, hint: hint, icon: icon, keyboard: keyboard, obscure: obscure),
    );
  });
}

/// A reusable modal form sheet. onSubmit returns an error string or null on success.
Future<bool?> showFormSheet(
  BuildContext context, {
  required String title,
  required List<Widget> Function(void Function(void Function())) builder,
  required Future<String?> Function() onSubmit,
  bool square = false, // admin/LMS panels use squared corners
  bool big = false, // roomier, width-capped, scrolling body (for long forms)
}) {
  // Captured from the caller (which is inside the page's SquareScope); the modal
  // itself is mounted on the root navigator, so we re-provide the scope below.
  final sq = square || SquareScope.of(context);
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // Dim + fade the background as the sheet pops up.
    barrierColor: Colors.black.withOpacity(0.45),
    builder: (ctx) {
      final p = Palette.of(ctx);
      bool busy = false;
      String? err;
      return StatefulBuilder(builder: (ctx, setS) {
        final saveBtn = PrimaryButton(
          label: 'Save',
          busy: busy,
          square: true,
          onPressed: () async {
            setS(() { busy = true; err = null; });
            final e = await onSubmit();
            if (e == null) {
              if (ctx.mounted) Navigator.pop(ctx, true);
            } else {
              setS(() { busy = false; err = e; });
            }
          },
        );
        return SquareScope(square: sq, child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: big ? 720 : double.infinity,
                maxHeight: MediaQuery.of(ctx).size.height * (big ? 0.92 : 0.85),
              ),
              child: Container(
                margin: const EdgeInsets.all(10),
                padding: EdgeInsets.all(big ? 24 : 20),
                decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.zero),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Center(child: Text(title, style: AppleTheme.title2(ctx))),
                  const SizedBox(height: 16),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        ...builder(setS),
                        if (err != null) ...[
                          const SizedBox(height: 12),
                          Text(err!, style: AppleTheme.footnote(ctx).copyWith(color: AppleColors.red)),
                        ],
                      ]),
                    ),
                  ),
                  const SizedBox(height: 18),
                  saveBtn,
                  const SizedBox(height: 6),
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: TextStyle(color: p.secondary))),
                ]),
              ),
            ),
          ),
        ));
      });
    },
  );
}
