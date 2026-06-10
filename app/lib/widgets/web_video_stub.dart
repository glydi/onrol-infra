import 'package:flutter/widgets.dart';

// Non-web fallback (never used on mobile, which plays HLS natively via
// video_player). Present so the conditional import compiles on all platforms.
Widget hlsVideoElement(String url) => const SizedBox.shrink();
