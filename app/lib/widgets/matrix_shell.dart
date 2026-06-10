import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// One control in the matrix. Either opens a [page] in-place, or runs [onTap]
/// as an action (e.g. New Course, Sign Out).
class MatrixItem {
  const MatrixItem({
    required this.icon,
    required this.label,
    required this.color,
    this.page,
    this.onTap,
  });
  final IconData icon;
  final String label;
  final Color color;
  final Widget? page;
  final VoidCallback? onTap;
}

/// The whole UI is the matrix — no sidebar, no menu bar, no app bar.
///
///   1 0 1 0 1
///   0 1 0 1 0     1 = a control (tile), 0 = blank space.
///   1 0 1 0 1
///
/// Items fill the `1` cells in order, expanding to as many rows as needed.
/// Tapping a tile that has a [MatrixItem.page] slides that page in over the
/// matrix, with a back chevron to return; tapping an action tile runs it.
class MatrixShell extends StatefulWidget {
  const MatrixShell({super.key, required this.title, this.subtitle, required this.items});
  final String title;
  final String? subtitle;
  final List<MatrixItem> items;

  @override
  State<MatrixShell> createState() => _MatrixShellState();
}

class _MatrixShellState extends State<MatrixShell> {
  static const _cols = 4;
  static const _rows = 4;
  MatrixItem? _open;

  void _tap(MatrixItem item) {
    if (item.page != null) {
      setState(() => _open = item);
    } else {
      item.onTap?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 320),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, anim) {
          final isMatrix = child.key == const ValueKey('matrix');
          final slide = Tween<Offset>(
            begin: Offset(0, isMatrix ? -0.04 : 0.06),
            end: Offset.zero,
          ).animate(anim);
          return FadeTransition(opacity: anim, child: SlideTransition(position: slide, child: child));
        },
        child: _open == null
            ? _matrixView(key: const ValueKey('matrix'))
            : _pageView(_open!, key: ValueKey(_open!.label)),
      ),
    );
  }

  Widget _matrixView({Key? key}) {
    final p = Palette.of(context);
    return SafeArea(
      key: key,
      child: LayoutBuilder(builder: (context, c) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 22, 16, 22),
          child: ConstrainedBox(
            // Fill at least the viewport so Center can center vertically;
            // scroll only if the content is taller than the screen.
            constraints: BoxConstraints(minHeight: c.maxHeight - 44),
            child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.title, style: AppleTheme.title2(context).copyWith(color: p.accent, fontWeight: FontWeight.w800)),
                if (widget.subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(widget.subtitle!, style: AppleTheme.subhead(context)),
                ],
                const SizedBox(height: 20),
                _checkerboard(),
              ],
            ),
          ),
            ),
          ),
        );
      }),
    );
  }

  Widget _checkerboard() {
    // Orange option block: two alternating orange shades for the checkerboard.
    const raisedColor = Color(0xFFFFB340); // lighter orange
    const recessedColor = AppleColors.orange; // 0xFFFF9500
    var idx = 0;
    final rows = <Widget>[];
    // A fixed 4×4 grid with every cell filled in an alternating two-tone
    // checkerboard (no gaps). Items sit on the "raised" cells in order.
    for (var r = 0; r < _rows; r++) {
      final cells = <Widget>[];
      for (var c = 0; c < _cols; c++) {
        final raised = (r + c).isEven;
        final item = (raised && idx < widget.items.length) ? widget.items[idx++] : null;
        cells.add(Expanded(
          child: AspectRatio(
            aspectRatio: 1,
            child: _Cell(
              color: raised ? raisedColor : recessedColor,
              item: item,
              onTap: item == null ? null : () => _tap(item),
            ),
          ),
        ));
      }
      rows.add(Row(children: cells));
    }
    // One square panel with a soft clay shadow; cells are flush inside it.
    return Container(
      decoration: const BoxDecoration(
        color: recessedColor,
        boxShadow: [BoxShadow(color: Color(0x55FF9500), offset: Offset(0, 12), blurRadius: 26, spreadRadius: -6)],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: rows),
    );
  }

  Widget _pageView(MatrixItem item, {Key? key}) {
    final p = Palette.of(context);
    return SafeArea(
      key: key,
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Minimal back affordance (a chevron, not a bar).
          Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              onTap: () => setState(() => _open = null),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(CupertinoIcons.chevron_back, size: 20, color: p.accent),
                  Text(widget.title, style: AppleTheme.body(context).copyWith(color: p.accent, fontSize: 16)),
                ]),
              ),
            ),
          ),
          Expanded(child: item.page!),
        ],
      ),
    );
  }
}

/// One flush checkerboard cell. Filled with [color]; if it has an [item] it
/// shows that control's icon + label and is pressable.
class _Cell extends StatefulWidget {
  const _Cell({required this.color, this.item, this.onTap});
  final Color color;
  final MatrixItem? item;
  final VoidCallback? onTap;

  @override
  State<_Cell> createState() => _CellState();
}

class _CellState extends State<_Cell> {
  double _scale = 1;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final cell = Container(
      color: widget.color,
      padding: const EdgeInsets.all(12),
      alignment: Alignment.center,
      child: item == null
          ? null
          : FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 58, height: 58,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [item.color, item.color.withOpacity(0.78)],
                        begin: Alignment.topLeft, end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [BoxShadow(color: item.color.withOpacity(0.4), offset: const Offset(0, 6), blurRadius: 14, spreadRadius: -3)],
                    ),
                    child: Icon(item.icon, color: Colors.white, size: 31),
                  ),
                  const SizedBox(height: 11),
                  Text(
                    item.label,
                    maxLines: 1,
                    style: AppleTheme.body(context).copyWith(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
    );

    if (widget.onTap == null) return cell;
    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.94),
      onTapUp: (_) => setState(() => _scale = 1),
      onTapCancel: () => setState(() => _scale = 1),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 90),
        child: cell,
      ),
    );
  }
}
