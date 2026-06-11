import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../widgets/watermark_overlay.dart';
import '../widgets/web_video_stub.dart' if (dart.library.html) '../widgets/web_video_web.dart';

/// Streaming video player with custom (Flutter-drawn) controls — there is no
/// native browser download button, and the identity watermark is drawn on top.
/// Streams progressively / via HLS; the file is never offered as a download.
class VideoPlayerScreen extends StatefulWidget {
  const VideoPlayerScreen({super.key, required this.url, required this.watermark, this.title = 'Video'});
  final String url;
  final String watermark;
  final String title;

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  VideoPlayerController? _c;
  bool _ready = false;
  String? _error;
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    // Web plays through an hls.js-backed <video> element (handles HLS on Chrome);
    // mobile uses video_player (native HLS via ExoPlayer/AVPlayer).
    if (!kIsWeb) {
      _c = VideoPlayerController.networkUrl(Uri.parse(widget.url));
      _c!.initialize().then((_) {
        _c!.play();
        _c!.addListener(_tick);
        if (mounted) setState(() => _ready = true);
      }).catchError((_) {
        if (mounted) setState(() => _error = 'Could not load this video.');
      });
    }
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c?.removeListener(_tick);
    _c?.dispose();
    super.dispose();
  }

  void _togglePlay() {
    final c = _c;
    if (c == null) return;
    setState(() {
      c.value.isPlaying ? c.pause() : c.play();
      _showControls = true;
    });
  }

  static const _accent = Color(0xFFFF4F2B);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0D),
      body: Stack(
        children: [
          // Centered, rounded video with a sensible max width on large screens.
          Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: WatermarkOverlay(
                  label: widget.watermark,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: kIsWeb ? _webPlayer() : _mobilePlayer(),
                  ),
                ),
              ),
            ),
          ),
          // Floating top bar (gradient, not a boxy app bar).
          Positioned(
            top: 0, left: 0, right: 0,
            child: SafeArea(
              bottom: false,
              child: Container(
                padding: const EdgeInsets.fromLTRB(6, 6, 16, 24),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xB3000000), Color(0x00000000)]),
                ),
                child: Row(children: [
                  IconButton(
                    icon: const Icon(CupertinoIcons.chevron_back, color: Colors.white, size: 26),
                    onPressed: () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                  ),
                ]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Web: hls.js-backed <video> (HLS on Chrome/Firefox, mp4 everywhere).
  Widget _webPlayer() => AspectRatio(aspectRatio: 16 / 9, child: hlsVideoElement(widget.url));

  // Mobile: video_player with custom controls.
  Widget _mobilePlayer() {
    if (_error != null) return Text(_error!, style: const TextStyle(color: Colors.white70));
    if (!_ready || _c == null) return const CupertinoActivityIndicator(color: Colors.white, radius: 14);
    final c = _c!;
    return GestureDetector(
      onTap: () => setState(() => _showControls = !_showControls),
      child: AspectRatio(
        aspectRatio: c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
        child: Stack(
          alignment: Alignment.center,
          children: [
            VideoPlayer(c),
            if (_showControls) _controls(),
          ],
        ),
      ),
    );
  }

  Widget _controls() {
    final c = _c!;
    return Stack(
      children: [
        Container(color: Colors.black26),
        Center(
          child: GestureDetector(
            onTap: _togglePlay,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: _accent.withOpacity(0.92), shape: BoxShape.circle, boxShadow: [BoxShadow(color: _accent.withOpacity(0.5), blurRadius: 18)]),
              child: Icon(c.value.isPlaying ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill, color: Colors.white, size: 32),
            ),
          ),
        ),
        Positioned(
          left: 12, right: 12, bottom: 12,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              VideoProgressIndicator(
                c,
                allowScrubbing: true,
                colors: const VideoProgressColors(playedColor: _accent, bufferedColor: Colors.white30, backgroundColor: Colors.white12),
                padding: const EdgeInsets.symmetric(vertical: 8),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(c.value.position), style: const TextStyle(color: Colors.white, fontSize: 12)),
                  Text(_fmt(c.value.duration), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
