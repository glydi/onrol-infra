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
class AppleCard extends StatelessWidget {
  const AppleCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.onTap});
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final card = Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(22),
        boxShadow: p.clay,
      ),
      child: child,
    );
    if (onTap == null) return card;
    return GestureDetector(onTap: onTap, behavior: HitTestBehavior.opaque, child: card);
  }
}

/// Full-width filled blue CTA with a press-scale animation.
class PrimaryButton extends StatefulWidget {
  const PrimaryButton({super.key, required this.label, required this.onPressed, this.busy = false, this.icon});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final IconData? icon;

  @override
  State<PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<PrimaryButton> {
  double _scale = 1;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final enabled = widget.onPressed != null && !widget.busy;
    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _scale = 0.97) : null,
      onTapUp: enabled ? (_) => setState(() => _scale = 1) : null,
      onTapCancel: enabled ? () => setState(() => _scale = 1) : null,
      onTap: enabled ? widget.onPressed : null,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 90),
        child: Container(
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: enabled
                  ? [p.accent, p.accent.withOpacity(0.82)]
                  : [p.secondary.withOpacity(0.4), p.secondary.withOpacity(0.4)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(18),
            boxShadow: enabled
                ? [BoxShadow(color: p.accent.withOpacity(0.38), offset: const Offset(0, 9), blurRadius: 20, spreadRadius: -3)]
                : null,
          ),
          child: widget.busy
              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.icon != null) ...[Icon(widget.icon, color: Colors.white, size: 19), const SizedBox(width: 8)],
                    Text(widget.label,
                        style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                  ],
                ),
        ),
      ),
    );
  }
}

/// iOS grouped text field. When [obscure] is set it shows a reveal (eye) toggle.
class AppleField extends StatefulWidget {
  const AppleField({super.key, required this.controller, required this.hint, this.icon, this.obscure = false, this.keyboard});
  final TextEditingController controller;
  final String hint;
  final IconData? icon;
  final bool obscure;
  final TextInputType? keyboard;

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
      borderRadius: BorderRadius.circular(4),
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
  const AppleSegmented({super.key, required this.labels, required this.selected, required this.onChanged});
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.dark ? AppleColors.darkCard2 : const Color(0xFFE9E9EB),
        borderRadius: BorderRadius.circular(9),
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
                  borderRadius: BorderRadius.circular(7),
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
