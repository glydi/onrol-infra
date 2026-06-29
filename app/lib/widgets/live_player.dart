import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'watermark_overlay.dart';
import 'web_video_stub.dart' if (dart.library.html) 'web_video_web.dart';

/// Embeddable player for a simulated-live session. It plays the server's
/// sliding-window HLS playlist, which only ever exposes segments up to "now" —
/// so there is no live edge to seek past. There is no scrubber, no ±10s, no
/// speed, and no real pause (pausing snaps back to the edge): to the viewer it
/// is an ordinary live stream. The per-student forensic watermark sits on top.
///
/// Web: hls.js in live mode (handles its own controls + LIVE badge in the
/// platform view). Mobile: video_player following the live edge, with a minimal
/// LIVE badge + mute/fullscreen overlay drawn in Flutter.
class LivePlayer extends StatefulWidget {
  const LivePlayer({super.key, required this.playlistUrl, required this.watermark, this.authToken = '', this.startEpochMs = 0, this.skewMs = 0});

  /// Absolute URL to the session's playlist.m3u8.
  final String playlistUrl;

  /// Per-student identity drawn as the drifting watermark.
  final String watermark;

  /// JWT — needed because both the playlist and the AES-128 key are auth-gated.
  final String authToken;

  /// Scheduled start (UTC ms since epoch) and device→server clock skew (ms).
  /// Playback position is pinned to (now + skew - start), skipping forward on
  /// drift so every video-second aligns with every real second.
  final int startEpochMs;
  final int skewMs;

  @override
  State<LivePlayer> createState() => _LivePlayerState();
}

class _LivePlayerState extends State<LivePlayer> {
  VideoPlayerController? _c;
  bool _ready = false;
  bool _muted = false;
  bool _fullscreen = false;
  String? _error;
  // Built ONCE so parent rebuilds (the live room polls /state every few seconds)
  // don't recreate the <video>/hls.js element and restart the stream.
  Widget? _webView;
  Timer? _syncTimer;

  // Exact video position "now" = (real now + skew - start), in seconds.
  double _target() {
    if (widget.startEpochMs <= 0) return -1;
    return (DateTime.now().millisecondsSinceEpoch + widget.skewMs - widget.startEpochMs) / 1000.0;
  }

  // Skip FORWARD to the wall-clock position whenever playback drifts behind
  // (buffering); never replay the missed seconds.
  void _syncMobile({bool force = false}) {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    final t = _target();
    if (t < 0) return;
    final cur = c.value.position.inMilliseconds / 1000.0;
    if (force || (cur - t).abs() > 2.0) {
      c.seekTo(Duration(milliseconds: (t < 0 ? 0 : t * 1000).round()));
    }
    if (!c.value.isPlaying) c.play();
  }

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      _c = VideoPlayerController.networkUrl(
        Uri.parse(widget.playlistUrl),
        httpHeaders: widget.authToken.isNotEmpty ? {'Authorization': 'Bearer ${widget.authToken}'} : const {},
      );
      _c!.initialize().then((_) {
        _c!.play();
        _syncMobile(force: true);
        if (mounted) setState(() => _ready = true);
      }).catchError((_) {
        if (mounted) setState(() => _error = 'Could not load the live stream.');
      });
      _syncTimer = Timer.periodic(const Duration(seconds: 1), (_) => _syncMobile());
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _c?.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _c?.setVolume(_muted ? 0 : 1);
  }

  Future<void> _toggleFullscreen() async {
    setState(() => _fullscreen = !_fullscreen);
    if (_fullscreen) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
  }

  @override
  Widget build(BuildContext context) {
    return WatermarkOverlay(
      label: widget.watermark,
      child: kIsWeb ? _webPlayer() : _mobilePlayer(),
    );
  }

  // Web: the platform view draws its own LIVE badge + mute/fullscreen controls.
  // Cached so it's created exactly once for this player.
  Widget _webPlayer() => _webView ??= AspectRatio(
        aspectRatio: 16 / 9,
        child: liveHlsVideoElement(widget.playlistUrl, authToken: widget.authToken, startEpochMs: widget.startEpochMs, skewMs: widget.skewMs),
      );

  Widget _mobilePlayer() {
    if (_error != null) {
      return AspectRatio(aspectRatio: 16 / 9, child: Center(child: Text(_error!, style: const TextStyle(color: Colors.white70))));
    }
    if (!_ready || _c == null) {
      return const AspectRatio(aspectRatio: 16 / 9, child: Center(child: CupertinoActivityIndicator(color: Colors.white, radius: 14)));
    }
    final c = _c!;
    final ar = c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio;
    final stack = Stack(
      alignment: Alignment.center,
      children: [
        VideoPlayer(c),
        if (c.value.isBuffering) const CupertinoActivityIndicator(color: Colors.white, radius: 16),
        // LIVE badge.
        const Positioned(top: 10, left: 10, child: _LiveBadge()),
        // Minimal controls.
        Positioned(
          bottom: 8, right: 8,
          child: Row(children: [
            _ctlBtn(_muted ? CupertinoIcons.volume_off : CupertinoIcons.volume_up, _toggleMute),
            const SizedBox(width: 6),
            _ctlBtn(_fullscreen ? CupertinoIcons.fullscreen_exit : CupertinoIcons.fullscreen, _toggleFullscreen),
          ]),
        ),
      ],
    );
    return _fullscreen
        ? SizedBox.expand(child: FittedBox(fit: BoxFit.contain, child: SizedBox(width: ar * 1000, height: 1000, child: stack)))
        : AspectRatio(aspectRatio: ar, child: stack);
  }

  Widget _ctlBtn(IconData icon, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: const BoxDecoration(color: Color(0x55000000), shape: BoxShape.circle),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      );
}

/// A small pulsing "● LIVE" pill (mobile; the web view draws its own).
class _LiveBadge extends StatefulWidget {
  const _LiveBadge();
  @override
  State<_LiveBadge> createState() => _LiveBadgeState();
}

class _LiveBadgeState extends State<_LiveBadge> with SingleTickerProviderStateMixin {
  late final AnimationController _ac = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat(reverse: true);

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), borderRadius: BorderRadius.circular(6)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        FadeTransition(
          opacity: Tween<double>(begin: 1, end: 0.3).animate(_ac),
          child: Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xFFFF3B30), shape: BoxShape.circle)),
        ),
        const SizedBox(width: 6),
        const Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
      ]),
    );
  }
}
