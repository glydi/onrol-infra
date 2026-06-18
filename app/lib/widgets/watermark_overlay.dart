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
    // ~2.5s per random position (60s / 24 steps).
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 60))
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

    // Jump the label to a fresh RANDOM position every step (it doesn't roam — it
    // pops up somewhere new), so a recording can't be cleaned by masking one spot.
    const steps = 24; // distinct positions per loop (~2.5s each)
    final i = (t * steps).floor();
    final rx = _rand(i * 2 + 1);
    final ry = _rand(i * 2 + 2);
    final dx = rx * max(1.0, size.width - tp.width);
    final dy = ry * max(1.0, size.height - tp.height);
    tp.paint(canvas, Offset(dx, dy));
  }

  // Deterministic pseudo-random in [0,1) from an integer step (no Random object,
  // so paints are pure and repeatable).
  double _rand(int n) {
    final v = sin(n * 12.9898 + 78.233) * 43758.5453;
    return v - v.floorToDouble();
  }

  @override
  bool shouldRepaint(_WatermarkPainter old) => old.t != t || old.label != label;
}
