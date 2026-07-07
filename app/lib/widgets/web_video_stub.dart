import 'package:flutter/widgets.dart';

// Non-web fallback (never used on mobile, which plays HLS natively via
// video_player). Present so the conditional import compiles on all platforms.
Widget hlsVideoElement(
  String url, {
  String authToken = '',
  double startAt = 0,
  bool autoPlay = true,
  void Function(double position, double duration)? onTime,
  void Function()? onEnded,
}) =>
    const SizedBox.shrink();

// Web-only live (HLS) element; mobile plays the live playlist via video_player.
Widget liveHlsVideoElement(
  String url, {
  String authToken = '',
  int startEpochMs = 0,
  int skewMs = 0,
  String title = '',
  String course = '',
  String instanceId = '',
}) =>
    const SizedBox.shrink();

void liveDisposeInstance(String id) {}

// Web-only host-control hooks (mobile draws these overlays in Flutter instead).
void liveSetMuted(bool muted) {}
void liveSetCover(String label) {}
void liveSetBanner(String text) {}
void liveSetPaused(bool paused) {}
