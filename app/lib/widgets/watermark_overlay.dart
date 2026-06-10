import 'dart:math';
import 'package:flutter/material.dart';

/// A translucent, slowly-drifting watermark of the logged-in student's identity,
/// drawn OVER the live video. Keyed to the JWT account (not to anything the user
/// typed into Zoho), so it's a reliable per-student forensic mark against
/// off-screen camera recording. See ARCHITECTURE.md §2.2 / §4.3.
class WatermarkOverlay extends StatefulWidget {
  const WatermarkOverlay({super.key, required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  State<WatermarkOverlay> createState() => _WatermarkOverlayState();
}

class _WatermarkOverlayState extends State<WatermarkOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 11))
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _ctrl,
              builder: (context, _) => CustomPaint(
                painter: _WatermarkPainter(widget.label, _ctrl.value),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _WatermarkPainter extends CustomPainter {
  _WatermarkPainter(this.label, this.t);
  final String label;
  final double t; // 0..1 loop

  @override
  void paint(Canvas canvas, Size size) {
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: Colors.white.withOpacity(0.16),
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    // Drift along a Lissajous-ish path so it never sits still or predictably.
    final dx = (sin(t * 2 * pi) * 0.5 + 0.5) * max(1, size.width - tp.width);
    final dy = (sin(t * 2 * pi * 1.6 + 1.1) * 0.5 + 0.5) * max(1, size.height - tp.height);
    tp.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(_WatermarkPainter old) => old.t != t || old.label != label;
}
