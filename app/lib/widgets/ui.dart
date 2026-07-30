import 'dart:ui';
import 'package:flutter/cupertino.dart' hide Text;
import 'package:flutter/material.dart' hide Text;
import 'package:onrol_app/widgets/upper_text.dart';

import '../theme.dart';
import '../theme_controller.dart';

// Corner radii for the boxes the ADMIN/LMS skin draws — cards, buttons,
// dialogs, sheets, fields. Values live here so the whole admin surface changes
// in one place. Student surfaces stay squared; see [adminRadius].
const double kRadiusCard = 12;
const double kRadiusButton = 9;
const double kRadiusDialog = 14;
const double kRadiusSheet = 16;
const double kRadiusField = 9;
const double kRadiusChip = 7;
const double kRadiusPill = 999; // fully rounded (progress bars, banner buttons)

/// Rounded corners belong to the **admin/LMS skin only**. Student surfaces keep
/// the squared look they've always had, so shared widgets ask for the radius
/// through here rather than using the constants directly.
BorderRadius adminRadius(Palette p, double r) =>
    p.admin ? BorderRadius.circular(r) : BorderRadius.zero;

/// The ONROL mark: a 5×5 checkerboard of glossy orange tiles.
///
/// Drawn rather than shipped as a bitmap so it stays sharp at any size and on
/// any pixel ratio, and so the brand orange comes from one place. The pattern is
/// every cell where `(row + column)` is odd — which lands the twelve tiles in a
/// diamond and leaves the four corners empty.
class OnrolMark extends StatelessWidget {
  const OnrolMark({super.key, this.size = 38});
  final double size;

  @override
  Widget build(BuildContext context) =>
      SizedBox(width: size, height: size, child: CustomPaint(painter: _OnrolMarkPainter()));
}

class _OnrolMarkPainter extends CustomPainter {
  // Lit top edge → saturated body → deeper foot, which is what reads as glass.
  static const _top = Color(0xFFFFA24D);
  static const _mid = Color(0xFFFF6A10);
  static const _foot = Color(0xFFD94E00);

  @override
  void paint(Canvas canvas, Size size) {
    const n = 5;
    final cell = size.width / n;
    final inset = cell * 0.07; // gap between tiles
    final r = Radius.circular(cell * 0.2);

    for (var row = 0; row < n; row++) {
      for (var col = 0; col < n; col++) {
        if ((row + col) % 2 == 0) continue; // corners and centre gaps stay empty
        final tile = RRect.fromRectAndRadius(
          Rect.fromLTWH(col * cell + inset, row * cell + inset,
              cell - inset * 2, cell - inset * 2),
          r,
        );
        canvas.drawRRect(
          tile,
          Paint()
            ..shader = const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [_top, _mid, _foot],
              stops: [0.0, 0.55, 1.0],
            ).createShader(tile.outerRect),
        );
        // Specular strip across the upper third — the bevel in the original.
        final gloss = RRect.fromRectAndRadius(
          Rect.fromLTWH(tile.left + tile.width * 0.16, tile.top + tile.height * 0.12,
              tile.width * 0.68, tile.height * 0.26),
          Radius.circular(cell * 0.1),
        );
        canvas.drawRRect(gloss, Paint()..color = Colors.white.withValues(alpha: 0.28));
      }
    }
  }

  @override
  bool shouldRepaint(_OnrolMarkPainter oldDelegate) => false;
}

/// Entrance animation for admin content: a short fade with a small rise.
/// [index] staggers items in a list so a grid resolves in sequence rather than
/// all at once. Honours the OS "reduce motion" setting — when that's on, or
/// when [enabled] is false, the child renders immediately with no animation.
class FadeInUp extends StatefulWidget {
  const FadeInUp({super.key, required this.child, this.index = 0, this.enabled = true});
  final Widget child;
  final int index;
  final bool enabled;

  @override
  State<FadeInUp> createState() => _FadeInUpState();
}

class _FadeInUpState extends State<FadeInUp> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 320));
  late final Animation<double> _fade =
      CurvedAnimation(parent: _c, curve: Curves.easeOut);
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.06), // ~6% of its own height, not a big swoop
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // Reduce-motion (or disabled): jump straight to the resolved state.
    if (!widget.enabled || MediaQuery.maybeOf(context)?.disableAnimations == true) {
      _c.value = 1;
      return;
    }
    // Stagger, capped so a long list never crawls in.
    final delay = Duration(milliseconds: (widget.index * 45).clamp(0, 360));
    Future<void>.delayed(delay, () { if (mounted) _c.forward(); });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _fade, child: SlideTransition(position: _slide, child: widget.child));
}

/// Compact tinted action — sized to its label rather than the full width, and
/// it highlights on hover instead of scaling. Use where a full-width
/// [PrimaryButton] would shout (e.g. "Create batch" beside a list).
class SmallActionButton extends StatefulWidget {
  const SmallActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.filled = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  /// Solid dark fill instead of the accent tint — for the one primary action
  /// on a page that should read as the obvious thing to press.
  final bool filled;

  @override
  State<SmallActionButton> createState() => _SmallActionButtonState();
}

class _SmallActionButtonState extends State<SmallActionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final on = widget.onPressed != null;
    final hot = _hover && on;
    // Solid variant: a deep ink slab that stays dark in either theme, so the
    // primary action reads the same way light or dark.
    const darkFill = Color(0xFF1A1A1A);
    const darkHover = Color(0xFF333333);
    final Color bg = widget.filled
        ? (on ? (hot ? darkHover : darkFill) : p.secondary.withValues(alpha: 0.35))
        : p.accent.withValues(alpha: hot ? 0.20 : 0.10);
    final Color fg = widget.filled
        ? Colors.white
        : (on ? p.accent : p.secondary);
    return MouseRegion(
      cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
          decoration: BoxDecoration(
            // Hover shifts the fill — no scale "pop".
            color: bg,
            borderRadius: adminRadius(p, kRadiusField),
            border: Border.all(
                color: widget.filled
                    ? Colors.transparent
                    : (hot ? p.accent : Colors.transparent)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(widget.icon, size: 17, color: fg),
            const SizedBox(width: 7),
            Text(widget.label,
                style: TextStyle(color: fg, fontSize: 14, fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
    );
  }
}

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
    // Only clickable boxes highlight — a static panel lighting up reads as
    // interactive when it isn't.
    final hovered = interactive && _hover;
    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      width: double.infinity,
      padding: widget.padding,
      decoration: BoxDecoration(
        color: p.card,
        // `square: true` selects the ADMIN styling — it no longer means radius
        // 0. Admin boxes are rounded; student surfaces stay squared.
        borderRadius: adminRadius(p, kRadiusCard),
        // Admin cards float on the tinted ground with the one shadow style; no
        // outline (a hover lift is signalled by a slightly stronger shadow, not
        // a hard border). Student surfaces keep their separator hairline.
        border: Border.all(
            color: p.admin ? Colors.transparent : (hovered ? p.accent : p.separator)),
        boxShadow: p.admin
            ? (hovered ? p.softHover : p.soft)
            : (hovered
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                      spreadRadius: -6,
                    ),
                  ]
                : null),
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

/// One choice in a [FilterDropdown].
class FilterOption<T> {
  const FilterOption(this.value, this.label, {this.hint});
  final T value;
  final String label;

  /// Optional second line in the menu — room to say what a metric measures
  /// without lengthening the button itself.
  final String? hint;
}

/// Compact labelled dropdown for dashboard filters.
///
/// Generic over the value type so one widget serves a day range (`int`), a
/// course or batch code (`String`) and a metric enum alike — adding a filter is
/// a list of options, not another bespoke control. Renders as `LABEL  value ⌄`
/// so a row of them reads as a sentence about what the chart is showing.
class FilterDropdown<T> extends StatefulWidget {
  const FilterDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.icon,
    this.maxWidth = 190,
  });
  final String label;
  final T value;
  final List<FilterOption<T>> options;
  final ValueChanged<T> onChanged;
  final IconData? icon;
  final double maxWidth;

  @override
  State<FilterDropdown<T>> createState() => _FilterDropdownState<T>();
}

class _FilterDropdownState<T> extends State<FilterDropdown<T>> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    if (widget.options.isEmpty) return const SizedBox.shrink();
    // A value that no longer exists (e.g. the selected batch after switching
    // course) falls back to the first option rather than rendering blank.
    final sel = widget.options.firstWhere((o) => o.value == widget.value,
        orElse: () => widget.options.first);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: PopupMenuButton<T>(
        tooltip: '',
        position: PopupMenuPosition.under,
        color: p.card,
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: adminRadius(p, kRadiusField)),
        onSelected: widget.onChanged,
        itemBuilder: (_) => [
          for (final o in widget.options)
            PopupMenuItem<T>(
              value: o.value,
              height: o.hint == null ? 38 : 50,
              child: Row(children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(o.label,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight:
                                  o.value == sel.value ? FontWeight.w700 : FontWeight.w500,
                              color: o.value == sel.value ? p.accent : p.label)),
                      if (o.hint != null)
                        Text(o.hint!,
                            style: TextStyle(fontSize: 10.5, color: p.secondary)),
                    ],
                  ),
                ),
                if (o.value == sel.value)
                  Icon(CupertinoIcons.checkmark_alt, size: 14, color: p.accent),
              ]),
            ),
        ],
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          constraints: BoxConstraints(maxWidth: widget.maxWidth),
          decoration: BoxDecoration(
            color: _hover ? p.separator.withValues(alpha: 0.55) : p.card2,
            borderRadius: BorderRadius.circular(kRadiusChip),
            border: Border.all(color: _hover ? p.accent : p.separator),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (widget.icon != null) ...[
              Icon(widget.icon, size: 13, color: p.secondary),
              const SizedBox(width: 5),
            ],
            Text('${widget.label} ',
                style: TextStyle(
                    fontSize: 10.5, fontWeight: FontWeight.w600, color: p.secondary)),
            Flexible(
              child: Text(sel.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5, fontWeight: FontWeight.w700, color: p.label)),
            ),
            const SizedBox(width: 3),
            Icon(CupertinoIcons.chevron_down, size: 11, color: p.secondary),
          ]),
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
  Widget _content(bool white) => widget.busy
      ? SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: white ? Colors.white : Colors.black54))
      : LayoutBuilder(
          builder: (context, c) {
            final reserve = widget.icon == null ? 24.0 : 52.0;
            final labelMax = c.maxWidth.isFinite ? (c.maxWidth - reserve).clamp(24.0, 220.0) : 220.0;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.icon != null) ...[Icon(widget.icon, color: white ? Colors.white : Colors.black87, size: 20), const SizedBox(width: 8)],
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: labelMax),
                    child: Text(widget.label,
                        maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false,
                        style: TextStyle(color: white ? Colors.white : Colors.black87, fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: 0.2)),
                  ),
                ],
              ),
            );
          },
        );

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final enabled = widget.onPressed != null && !widget.busy;

    // Admin: Material filled button — solid black fill, ink ripple + a small
    // resting elevation that lifts on hover. Replaces the old press-scale.
    if (widget.square) {
      final fill = enabled ? const Color(0xFF1A1A1A) : p.secondary.withOpacity(0.30);
      final radius = adminRadius(p, kRadiusButton);
      return MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: enabled
                ? [BoxShadow(color: Colors.black.withOpacity(_hover ? 0.28 : 0.18), offset: Offset(0, _hover ? 6 : 3), blurRadius: _hover ? 16 : 8, spreadRadius: -4)]
                : null,
          ),
          child: Material(
            color: fill,
            borderRadius: radius,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: enabled ? widget.onPressed : null,
              splashColor: Colors.white.withOpacity(0.18),
              highlightColor: Colors.white.withOpacity(0.06),
              child: SizedBox(height: 46, child: Center(child: _content(true))),
            ),
          ),
        ),
      );
    }

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
          height: widget.square ? 52 : 50,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            // Admin (square): solid BLACK primary — the glassmorphism spec keeps
            // the neon lime for highlights, so the main CTA is black/white.
            // Else (student): gradient accent CTA.
            color: widget.square
                ? (enabled ? const Color(0xFF1A1A1A) : p.secondary.withOpacity(0.35))
                : null,
            gradient: widget.square
                ? null
                : LinearGradient(
                    colors: enabled
                        ? [p.accent, p.accent.withOpacity(0.82)]
                        : [p.secondary.withOpacity(0.4), p.secondary.withOpacity(0.4)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
            // Admin: a soft ambient drop shadow so the black pill floats.
            borderRadius: adminRadius(p, kRadiusButton),
            boxShadow: !enabled
                ? null
                : widget.square
                    ? [
                        BoxShadow(color: Colors.black.withOpacity(0.22), offset: Offset(0, _scale < 1 ? 2 : 8), blurRadius: _scale < 1 ? 8 : 20, spreadRadius: -6),
                      ]
                    : [BoxShadow(color: p.accent.withOpacity(0.20), offset: const Offset(0, 3), blurRadius: 8, spreadRadius: -2)],
          ),
          child: widget.busy
              ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
              : LayoutBuilder(
                  builder: (context, c) {
                    final reserve = widget.icon == null ? 24.0 : 52.0;
                    final labelMax = c.maxWidth.isFinite ? (c.maxWidth - reserve).clamp(24.0, 220.0) : 220.0;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (widget.icon != null) ...[Icon(widget.icon, color: Colors.white, size: 20), const SizedBox(width: 8)],
                          ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: labelMax),
                            child: Text(
                              widget.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
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
        shape: RoundedRectangleBorder(borderRadius: adminRadius(p, kRadiusDialog)),
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
        shape: RoundedRectangleBorder(borderRadius: adminRadius(p, kRadiusDialog)),
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
  const AppleField({super.key, required this.controller, required this.hint, this.icon, this.obscure = false, this.keyboard, this.autofillHints, this.minLines, this.maxLines = 1});
  final TextEditingController controller;
  final String hint;
  final IconData? icon;
  final bool obscure;
  final TextInputType? keyboard;
  final List<String>? autofillHints; // lets browsers / password managers offer to save & fill
  // For multi-line inputs (e.g. a Markdown description): grows from minLines up
  // to maxLines (pass maxLines: null for unbounded). Defaults to a single line.
  final int? minLines;
  final int? maxLines;

  @override
  State<AppleField> createState() => _AppleFieldState();
}

class _AppleFieldState extends State<AppleField> {
  late bool _hidden = widget.obscure;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final multiline = (widget.maxLines == null || widget.maxLines! > 1);
    return Row(
      // A multi-line field grows downward, so pin the leading icon to the top
      // instead of vertically centering it against the whole box.
      crossAxisAlignment: multiline ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        if (widget.icon != null) ...[
          Padding(
            padding: EdgeInsets.only(top: multiline ? 10 : 0),
            child: Icon(widget.icon, size: 19, color: p.secondary),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: TextField(
            controller: widget.controller,
            obscureText: _hidden,
            keyboardType: multiline ? TextInputType.multiline : widget.keyboard,
            minLines: widget.minLines,
            maxLines: widget.obscure ? 1 : widget.maxLines,
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
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 10),
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
      borderRadius: adminRadius(p, kRadiusPill),
      child: LinearProgressIndicator(
        value: value.clamp(0, 1),
        minHeight: 7,
        backgroundColor: p.dark ? AppleColors.darkCard2 : const Color(0xFFEDEDED),
        // Admin progress carries the signature lime highlight by default.
        valueColor: AlwaysStoppedAnimation(color ?? (p.admin && !p.dark ? AdminColors.lime : p.accent)),
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
        borderRadius: adminRadius(p, kRadiusButton),
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
                  borderRadius: adminRadius(p, kRadiusChip),
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

Widget sheetField(TextEditingController c, String hint, IconData icon, {TextInputType? keyboard, bool square = false, bool obscure = false, int? minLines, int? maxLines = 1}) {
  return Builder(builder: (context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(color: p.card2, borderRadius: adminRadius(p, kRadiusField)),
      child: AppleField(controller: c, hint: hint, icon: icon, keyboard: keyboard, obscure: obscure, minLines: minLines, maxLines: maxLines),
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
  bool full = false, // nearly full-screen centered panel (for big editors)
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
        final screenH = MediaQuery.of(ctx).size.height;
        final screenW = MediaQuery.of(ctx).size.width;
        final wide = big || full; // centered panel (not a shrink-to-content sheet)
        // `big` renders a large CENTERED panel with a generous fixed height;
        // `full` goes nearly edge-to-edge (for big editors) but never truly full.
        return SquareScope(square: sq, child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Align(
            alignment: wide ? Alignment.center : Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: full ? screenW * 0.96 : (big ? 760 : double.infinity),
                maxHeight: screenH * (full ? 0.97 : (wide ? 0.9 : 0.85)),
              ),
              child: Container(
                margin: EdgeInsets.all(full ? 12 : (big ? 16 : 10)),
                height: full ? screenH * 0.95 : (big ? (screenH * 0.82).clamp(0.0, 820.0) : null),
                padding: EdgeInsets.all(full ? 22 : (big ? 26 : 20)),
                decoration: BoxDecoration(color: p.card, borderRadius: adminRadius(p, kRadiusSheet)),
                child: Column(mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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

// Canonical batch code, e.g. "AIG 01 07 26 AA" — course short form (upper) +
// batch number + start month + start year (numeric parts zero-padded to 2
// digits) + a two-letter code (upper). Returns '' if any part is blank.
String buildBatchCode(String course, String batch, String month, String year, String code) {
  final c = course.trim().toUpperCase();
  String pad(String s) {
    final n = s.trim();
    return n.isEmpty ? '' : n.padLeft(2, '0');
  }
  final b = pad(batch), m = pad(month), y = pad(year);
  final s = code.trim().toUpperCase();
  if (c.isEmpty || b.isEmpty || m.isEmpty || y.isEmpty || s.isEmpty) return '';
  return '$c $b $m $y $s';
}

/// Five-field batch-code input (course short form · batch no. · start month ·
/// start year · two-letter code) that builds a code like "AIG 01 07 26 AA".
/// Replaces the old plain integer batch everywhere a batch is entered.
class BatchCodeField extends StatefulWidget {
  const BatchCodeField({this.initial, required this.onChanged});
  final String? initial;
  final ValueChanged<String> onChanged; // full code, or '' when incomplete

  @override
  State<BatchCodeField> createState() => BatchCodeFieldState();
}

class BatchCodeFieldState extends State<BatchCodeField> {
  late final TextEditingController _course, _batch, _month, _year, _code;

  @override
  void initState() {
    super.initState();
    final raw = (widget.initial ?? '').trim();
    final parts = raw.isEmpty ? <String>[] : raw.split(RegExp(r'\s+'));
    // Accept a legacy 4-part code (no trailing letters) as well as the 5-part one.
    final ok = parts.length >= 4;
    String at(int i) => ok && i < parts.length ? parts[i] : '';
    _course = TextEditingController(text: (ok ? at(0) : 'aig').toUpperCase()); // default course code
    _batch = TextEditingController(text: at(1));
    _month = TextEditingController(text: at(2));
    _year = TextEditingController(text: at(3));
    _code = TextEditingController(text: at(4).toUpperCase());
  }

  @override
  void dispose() {
    for (final c in [_course, _batch, _month, _year, _code]) {
      c.dispose();
    }
    super.dispose();
  }

  void _emit() {
    // Course code and the trailing two-letter code are always uppercase; force
    // it as the user types.
    for (final ctl in [_course, _code]) {
      final up = ctl.text.toUpperCase();
      if (up != ctl.text) {
        ctl.value = ctl.value.copyWith(
          text: up,
          selection: TextSelection.collapsed(offset: up.length),
        );
      }
    }
    setState(() {}); // refresh the live preview
    widget.onChanged(buildBatchCode(_course.text, _batch.text, _month.text, _year.text, _code.text));
  }

  // Live "AIG ** ** ** **" preview — ** for any group not yet filled.
  String _preview() {
    String g(TextEditingController ctl) {
      final n = ctl.text.trim();
      return n.isEmpty ? '**' : n.padLeft(2, '0');
    }
    final c = _course.text.trim().toUpperCase();
    final s = _code.text.trim().toUpperCase();
    return '${c.isEmpty ? 'AIG' : c} ${g(_batch)} ${g(_month)} ${g(_year)} ${s.isEmpty ? '**' : s}';
  }

  Widget _cell(TextEditingController c, String label, String hint, {int flex = 1, bool digits = false}) {
    final p = Palette.of(context);
    return Expanded(
      flex: flex,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: AppleTheme.footnote(context).copyWith(color: p.secondary, fontSize: 11)),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: p.card2, border: Border.all(color: p.separator)),
          child: TextField(
            controller: c,
            keyboardType: digits ? TextInputType.number : TextInputType.text,
            textAlign: TextAlign.center,
            onChanged: (_) => _emit(),
            style: AppleTheme.body(context),
            decoration: InputDecoration(border: InputBorder.none, isDense: true, hintText: hint, hintStyle: TextStyle(color: p.secondary)),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        _cell(_course, 'Course', 'AIG', flex: 3),
        const SizedBox(width: 8),
        _cell(_batch, 'Batch', '**', digits: true),
        const SizedBox(width: 8),
        _cell(_month, 'Month', '**', digits: true),
        const SizedBox(width: 8),
        _cell(_year, 'Year', '**', digits: true),
        const SizedBox(width: 8),
        _cell(_code, 'Code', 'AA', flex: 2),
      ]),
      const SizedBox(height: 8),
      Text(_preview(), style: AppleTheme.body(context).copyWith(fontWeight: FontWeight.w700, letterSpacing: 1.5, color: p.accent)),
    ]);
  }
}
