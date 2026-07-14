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
          body: Row(children: [
            _Sidebar(
              auth: widget.auth,
              dests: widget.destinations,
              index: _i,
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
          backgroundColor: admin ? const Color(0xFF111418) : p.bg,
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
  const _Sidebar({required this.auth, required this.dests, required this.index, required this.onSelect, required this.onSignOut});
  final AuthService auth;
  final List<NavDest> dests;
  final int index;
  final ValueChanged<int> onSelect;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final admin = p.admin;
    final sideBg = admin ? const Color(0xFF111418) : p.bg;
    final sideBorder = admin ? const Color(0xFF252B33) : p.separator;
    final sideMuted = admin ? const Color(0xFF7D8794) : p.secondary;
    return Container(
      width: admin ? 272 : 256,
      decoration: BoxDecoration(
        color: sideBg,
        border: Border(right: BorderSide(color: sideBorder)),
      ),
      padding: EdgeInsets.fromLTRB(14, MediaQuery.of(context).padding.top + 18, 14, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Container(
              width: 38, height: 38,
              decoration: BoxDecoration(
                color: admin ? p.accent : null,
                borderRadius: BorderRadius.zero,
                gradient: admin ? null : const LinearGradient(colors: [AppleColors.blue, AppleColors.purple], begin: Alignment.topLeft, end: Alignment.bottomRight),
              ),
              child: const Icon(CupertinoIcons.book_fill, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('ONROL', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppleTheme.title2(context).copyWith(color: admin ? Colors.white : p.accent, fontWeight: FontWeight.w800)),
                if (admin) Text('LMS ADMIN', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppleTheme.footnote(context).copyWith(color: sideMuted, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.1)),
              ]),
            ),
          ]),
          const SizedBox(height: 22),
          ..._navItems(context),
          const Spacer(),
          Text('Appearance', style: AppleTheme.footnote(context).copyWith(color: sideMuted)),
          const SizedBox(height: 8),
          Container(
            padding: admin ? const EdgeInsets.all(4) : EdgeInsets.zero,
            decoration: BoxDecoration(
              color: admin ? const Color(0xFF161A20) : Colors.transparent,
              border: admin ? Border.all(color: const Color(0xFF252B33)) : null,
              borderRadius: BorderRadius.zero,
            ),
            child: const ThemeToggle(),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: admin ? const Color(0xFF161A20) : p.card,
              border: Border.all(color: admin ? const Color(0xFF252B33) : p.separator),
              borderRadius: BorderRadius.zero,
              boxShadow: admin ? null : p.clay,
            ),
            child: Row(children: [
              Avatar(name: auth.user?.fullName ?? 'U', size: 36),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(auth.user?.fullName ?? 'User', style: AppleTheme.body(context).copyWith(fontSize: 14, fontWeight: FontWeight.w600, color: admin ? Colors.white : null), maxLines: 1, overflow: TextOverflow.ellipsis),
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
    final sideMuted = admin ? const Color(0xFF7D8794) : p.secondary;
    final out = <Widget>[];
    String? lastSection;
    for (var i = 0; i < dests.length; i++) {
      final section = dests[i].section;
      if (section.isNotEmpty && section != lastSection) {
        out.add(Padding(
          padding: EdgeInsets.only(top: out.isEmpty ? 0 : 18, bottom: 7, left: 6),
          child: Text(section.toUpperCase(), style: AppleTheme.footnote(context).copyWith(color: sideMuted, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.9)),
        ));
        lastSection = section;
      }
      out.add(_tile(context, dests[i], i == index, () => onSelect(i)));
    }
    return out;
  }

  Widget _tile(BuildContext context, NavDest d, bool on, VoidCallback onTap) {
    final p = Palette.of(context);
    final admin = p.admin;
    final sideInk = admin ? const Color(0xFFC7CFDA) : p.label;
    final sideMuted = admin ? const Color(0xFF7D8794) : p.secondary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: on ? p.accent : Colors.transparent,
            borderRadius: BorderRadius.zero,
          ),
          child: Row(children: [
            Icon(d.icon, size: 20, color: on ? Colors.white : sideMuted),
            const SizedBox(width: 12),
            Expanded(
              child: Text(d.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppleTheme.body(context).copyWith(fontSize: 14.5, fontWeight: on ? FontWeight.w700 : FontWeight.w600, color: on ? Colors.white : sideInk)),
            ),
            if (d.badge > 0)
              Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                constraints: const BoxConstraints(minWidth: 18),
                decoration: BoxDecoration(color: on ? Colors.white : AppleColors.red, borderRadius: BorderRadius.circular(9)),
                child: Text(d.badge > 99 ? '99+' : '${d.badge}',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: on ? p.accent : Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
              ),
          ]),
        ),
      ),
    );
  }
}
