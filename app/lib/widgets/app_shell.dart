import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../theme.dart';
import 'ui.dart';

class NavDest {
  const NavDest(this.icon, this.label);
  final IconData icon;
  final String label;
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
                Expanded(child: body),
              ]),
            ),
          ]),
        );
      }

      return Scaffold(
        drawer: Drawer(
          backgroundColor: p.bg,
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
          title: Text(widget.destinations[_i].label, style: AppleTheme.headline(context)),
          actions: widget.trailing != null ? [Padding(padding: const EdgeInsets.only(right: 12), child: widget.trailing!)] : null,
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
    return Container(
      width: 256,
      decoration: BoxDecoration(color: p.bg),
      padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + 22, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Container(
              width: 38, height: 38,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: const LinearGradient(colors: [AppleColors.blue, AppleColors.purple], begin: Alignment.topLeft, end: Alignment.bottomRight),
              ),
              child: const Icon(CupertinoIcons.book_fill, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            Text('ONROL', style: AppleTheme.title2(context).copyWith(color: p.accent, fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 26),
          ...List.generate(dests.length, (i) => _tile(context, dests[i], i == index, () => onSelect(i))),
          const Spacer(),
          Text('Appearance', style: AppleTheme.footnote(context)),
          const SizedBox(height: 8),
          const ThemeToggle(),
          const SizedBox(height: 16),
          AppleCard(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Avatar(name: auth.user?.fullName ?? 'U', size: 36),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(auth.user?.fullName ?? 'User', style: AppleTheme.body(context).copyWith(fontSize: 14, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text((auth.user?.role ?? '').toUpperCase(), style: AppleTheme.footnote(context).copyWith(fontSize: 10)),
                ]),
              ),
              GestureDetector(onTap: onSignOut, child: const Icon(CupertinoIcons.square_arrow_right, size: 20, color: AppleColors.red)),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, NavDest d, bool on, VoidCallback onTap) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: on ? p.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            Icon(d.icon, size: 20, color: on ? Colors.white : p.secondary),
            const SizedBox(width: 12),
            Text(d.label, style: AppleTheme.body(context).copyWith(fontSize: 15, fontWeight: on ? FontWeight.w600 : FontWeight.w500, color: on ? Colors.white : p.label)),
          ]),
        ),
      ),
    );
  }
}
