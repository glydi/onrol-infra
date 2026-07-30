import 'package:flutter/cupertino.dart' hide Text;
import 'package:flutter/material.dart' hide Text;
import 'package:onrol_app/widgets/upper_text.dart';

import '../services/auth_service.dart';
import '../theme.dart';
import 'ui.dart';

class NavDest {
  const NavDest(this.icon, this.label, {this.section = '', this.badge = 0});
  final IconData icon;
  final String label;
  final String section;
  final int badge; // >0 shows a red count pill on the nav item
}

/// Responsive app shell: a claymorphic left **sidebar** on wide screens, and a
/// top **menu bar** + slide-in drawer on narrow screens. Switches between pages.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.auth,
    required this.destinations,
    required this.pages,
    required this.onSignOut,
    this.trailing,
    this.initialIndex = 0,
  });

  final AuthService auth;
  final List<NavDest> destinations;
  final List<Widget> pages;
  final VoidCallback onSignOut;
  final Widget? trailing; // optional action shown in the menu bar (e.g. New Course)
  final int initialIndex;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late int _i = widget.initialIndex;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final admin = p.admin;
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= 900;
      final body = IndexedStack(index: _i, children: widget.pages);

      if (wide) {
        return Scaffold(
          // The ground shows in the gap around the floating sidebar.
          backgroundColor: p.bg,
          body: Row(children: [
            _Sidebar(
              auth: widget.auth,
              dests: widget.destinations,
              index: _i,
              floating: true,
              onSelect: (i) => setState(() => _i = i),
              onSignOut: widget.onSignOut,
            ),
            Expanded(
              child: Column(children: [
                if (widget.trailing != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 14, 18, 0),
                    child: Align(alignment: Alignment.centerRight, child: widget.trailing!),
                  ),
                // Cap the content to a comfortable width, centered — otherwise on
                // a wide screen everything (buttons especially) stretches the whole
                // width and reads as one long bar.
                Expanded(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(constraints: BoxConstraints(maxWidth: admin ? 1180 : 920), child: body),
                  ),
                ),
              ]),
            ),
          ]),
        );
      }

      return Scaffold(
        drawer: Drawer(
          backgroundColor: admin ? Colors.white : p.bg,
          child: _Sidebar(
            auth: widget.auth,
            dests: widget.destinations,
            index: _i,
            onSelect: (i) {
              Navigator.pop(context);
              setState(() => _i = i);
            },
            onSignOut: widget.onSignOut,
          ),
        ),
        appBar: AppBar(
          backgroundColor: p.bg,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: Text(widget.destinations[_i].label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppleTheme.headline(context)),
          actions: widget.trailing != null
              ? [Padding(padding: const EdgeInsets.only(right: 12), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 180), child: widget.trailing!))]
              : null,
        ),
        body: body,
      );
    });
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.auth,
    required this.dests,
    required this.index,
    required this.onSelect,
    required this.onSignOut,
    this.floating = false,
  });
  final AuthService auth;
  final List<NavDest> dests;
  /// Detached panel with a margin, rounded corners and a shadow (wide layout).
  /// False inside the mobile Drawer, which is already its own panel.
  final bool floating;
  final int index;
  final ValueChanged<int> onSelect;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final admin = p.admin;
    final sideBg = admin ? (p.dark ? AdminColors.darkCard : Colors.white) : p.bg;
    final sideBorder = admin ? p.separator : p.separator;
    final sideMuted = admin ? (p.dark ? const Color(0xFF7D8794) : AdminColors.lightMuted) : p.secondary;
    final float = floating && admin;
    return Container(
      width: admin ? 272 : 256,
      // Floating: sits inset from the edges so the ground shows all around it.
      margin: float ? const EdgeInsets.fromLTRB(14, 14, 0, 14) : EdgeInsets.zero,
      decoration: BoxDecoration(
        color: sideBg,
        borderRadius: float ? BorderRadius.circular(kRadiusSheet) : null,
        // Admin carries a hard outline all the way round, floating or not — on a
        // light panel a shadow alone doesn't separate it from a light ground.
        border: admin
            ? Border.all(color: sideBorder, width: 1.4)
            : (float ? null : Border(right: BorderSide(color: sideBorder))),
        boxShadow: float
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: p.dark ? 0.45 : 0.10),
                  blurRadius: 28,
                  offset: const Offset(0, 10),
                  spreadRadius: -10,
                ),
              ]
            : null,
      ),
      padding: EdgeInsets.fromLTRB(12, MediaQuery.of(context).padding.top + 14, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            // Admin flies the ONROL mark; the student shell keeps its gradient
            // book tile. The mark needs no plate behind it — it carries its own
            // shape, and a filled square would box it in.
            if (admin)
              const OnrolMark(size: 38)
            else
              Container(
                width: 38, height: 38,
                decoration: BoxDecoration(
                  borderRadius: adminRadius(p, kRadiusButton),
                  gradient: const LinearGradient(colors: [AppleColors.blue, AppleColors.purple], begin: Alignment.topLeft, end: Alignment.bottomRight),
                ),
                child: const Icon(CupertinoIcons.book_fill, color: Colors.white, size: 20),
              ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('ONROL', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppleTheme.title2(context).copyWith(color: admin ? (p.dark ? Colors.white : const Color(0xFF1A1A1A)) : p.accent, fontWeight: FontWeight.w800)),
                if (admin) Text('LMS ADMIN', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppleTheme.footnote(context).copyWith(color: sideMuted, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.1)),
              ]),
            ),
          ]),
          const SizedBox(height: 14),
          // The tiles are sized so the whole list clears a laptop viewport
          // without scrolling. The scroll view stays purely as a safety net for
          // very short windows — it should never actually engage.
          Expanded(
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _navItems(context),
              ),
            ),
          ),
          // Theme lives in Settings → Appearance; duplicating it here made the
          // sidebar taller for no gain.
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: admin ? (p.dark ? const Color(0xFF161A20) : AdminColors.lightCard2) : p.card,
              border: Border.all(color: admin ? p.separator : p.separator),
              borderRadius: adminRadius(p, kRadiusField),
              boxShadow: admin ? null : p.clay,
            ),
            child: Row(children: [
              Avatar(name: auth.user?.fullName ?? 'U', size: 36),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(auth.user?.fullName ?? 'User', style: AppleTheme.body(context).copyWith(fontSize: 14, fontWeight: FontWeight.w600, color: admin ? (p.dark ? Colors.white : const Color(0xFF1A1A1A)) : null), maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text((auth.user?.role ?? '').toUpperCase(), style: AppleTheme.footnote(context).copyWith(fontSize: 10, color: admin ? sideMuted : null)),
                ]),
              ),
              GestureDetector(onTap: onSignOut, child: const Icon(CupertinoIcons.square_arrow_right, size: 20, color: AppleColors.red)),
            ]),
          ),
        ],
      ),
    );
  }

  List<Widget> _navItems(BuildContext context) {
    final p = Palette.of(context);
    final admin = p.admin;
    final sideMuted = admin ? AdminColors.sideMuted : p.secondary;
    final out = <Widget>[];
    String? lastSection;
    for (var i = 0; i < dests.length; i++) {
      final section = dests[i].section;
      if (section.isNotEmpty && section != lastSection) {
        out.add(Padding(
          padding: EdgeInsets.only(top: out.isEmpty ? 2 : 11, bottom: 4, left: 10),
          child: Text(section.toUpperCase(), style: AppleTheme.footnote(context).copyWith(color: sideMuted, fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 1.0)),
        ));
        lastSection = section;
      }
      out.add(_tile(context, dests[i], i == index, () => onSelect(i)));
    }
    return out;
  }

  Widget _tile(BuildContext context, NavDest d, bool on, VoidCallback onTap) =>
      _NavTile(dest: d, selected: on, onTap: onTap);
}

/// One sidebar destination. Stateful purely so it can highlight under the
/// cursor — the selected item keeps its solid accent fill.
class _NavTile extends StatefulWidget {
  const _NavTile({required this.dest, required this.selected, required this.onTap});
  final NavDest dest;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NavTile> createState() => _NavTileState();
}

class _NavTileState extends State<_NavTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.dest;
    final on = widget.selected;
    final p = Palette.of(context);
    final admin = p.admin;
    final sideInk = admin ? (p.dark ? const Color(0xFFC7CFDA) : AdminColors.lightLabel) : p.label;
    final sideMuted = admin ? (p.dark ? const Color(0xFF7D8794) : AdminColors.lightMuted) : p.secondary;
    // Selected nav uses the signature lime with dark ink on top (glassmorphism).
    final selBg = admin ? AdminColors.lime : p.accent;
    final selInk = admin ? const Color(0xFF1A1A1A) : Colors.white;
    // Material-3 "left-bar indicator": the active item shows a thick rounded
    // accent bar on its left + bold coloured label; no heavy fill. Hover is a
    // quiet neutral wash. Student surfaces keep their original accent style.
    final active = admin ? AdminColors.secondaryAccent : p.accent;
    final iconColor = on ? active : (_hover ? (admin ? sideInk : p.accent) : sideMuted);
    final textColor = on ? (admin ? sideInk : selInk) : (_hover ? (admin ? sideInk : p.accent) : sideInk);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          padding: const EdgeInsets.only(right: 12, top: 7, bottom: 7),
          decoration: BoxDecoration(
            // Minimal: selected gets a faint tonal wash (Material state layer);
            // hover a lighter one. The left bar carries the "active" signal.
            color: admin
                ? (on
                    ? active.withValues(alpha: 0.08)
                    : (_hover ? Colors.black.withValues(alpha: 0.04) : Colors.transparent))
                : (on ? selBg : (_hover ? p.accent.withValues(alpha: 0.14) : Colors.transparent)),
            borderRadius: adminRadius(p, kRadiusButton),
          ),
          child: Row(children: [
            // Active indicator bar (admin only). Reserves its width always so
            // labels never shift when selection moves.
            if (admin)
              Container(
                width: 3.5,
                height: 20,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  color: on ? active : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                ),
              )
            else
              const SizedBox(width: 12),
            Icon(d.icon, size: 18, color: iconColor),
            const SizedBox(width: 12),
            Expanded(
              child: Text(d.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppleTheme.body(context).copyWith(fontSize: 13.5, fontWeight: on ? FontWeight.w700 : FontWeight.w500, color: textColor)),
            ),
            if (d.badge > 0)
              Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                constraints: const BoxConstraints(minWidth: 18),
                decoration: BoxDecoration(color: AppleColors.red, borderRadius: BorderRadius.circular(9)),
                child: Text(d.badge > 99 ? '99+' : '${d.badge}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
              ),
          ]),
        ),
      ),
      ),
    );
  }
}
