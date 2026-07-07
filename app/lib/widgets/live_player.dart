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
  const LivePlayer({super.key, required this.playlistUrl, required this.watermark, this.authToken = '', this.startEpochMs = 0, this.skewMs = 0, this.title = '', this.course = '', this.hostMuted = false, this.blank = false, this.paused = false, this.banner = '', this.slide = ''});

  /// Absolute URL to the session's playlist.m3u8.
  final String playlistUrl;

  /// Per-student identity drawn as the drifting watermark.
  final String watermark;

  /// JWT — needed because both the playlist and the AES-128 key are auth-gated.
  final String authToken;

  /// Scheduled start (UTC ms since epoch) and device→server clock skew (ms),
  /// passed through to the web player. The stream itself follows the server's
  /// live edge, so every viewer stays on the same server-defined second.
  final int startEpochMs;
  final int skewMs;

  /// Shown as the title in the OS/browser media panel (course as the subtitle).
  final String title;
  final String course;

  /// Host mute-all: when true the audio is silenced for this viewer regardless
  /// of their own mute button (used for pause / black-out / mute-all).
  final bool hostMuted;

  /// Host room-controls, mirrored from /state. On web these drive HTML overlays
  /// inside the video container (Flutter can't reliably paint over the <video>);
  /// on mobile they're drawn as a Flutter cover here in the player.
  final bool blank;
  final bool paused;
  final String banner;

  /// The presented slide image (data URI) shown over the video, or '' for none.
  final String slide;

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
  // Unique id so this player's web hls.js + <video> can be torn down on dispose
  // (otherwise the old element keeps playing audio → "two voices").
  static int _liveInstanceCounter = 0;
  final String _liveId = 'onrol-live-inst-${_liveInstanceCounter++}';

  // Follow the live edge. The server's sliding-window playlist has no end while
  // live, so the player treats it as a genuine live stream — there is nothing to
  // seek past and the OS media notification shows no scrubber. If we fall behind
  // the newest segment (a stall), jump FORWARD to the edge; never replay. All
  // viewers share the same server-defined window, so the edge is the same
  // wall-clock second for everyone. (On iOS the live duration is reported as
  // indefinite and AVPlayer holds the edge itself — there we just keep playing.)
  void _followEdge({bool force = false}) {
    if (widget.paused) return; // host paused → hold the frame, don't chase the edge
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    final durS = c.value.duration.inMilliseconds / 1000.0;
    if (durS > 2) {
      final edge = durS - 1.5; // sit ~1.5s behind the newest segment
      final cur = c.value.position.inMilliseconds / 1000.0;
      if (force || cur < edge - 4) {
        c.seekTo(Duration(milliseconds: (edge * 1000).round()));
      }
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
        _followEdge(force: true);
        _applyHostState();
        if (mounted) setState(() => _ready = true);
      }).catchError((_) {
        if (mounted) setState(() => _error = 'Could not load the live stream.');
      });
      _syncTimer = Timer.periodic(const Duration(seconds: 1), (_) => _followEdge());
    } else {
      // The web element is created asynchronously by the platform view; re-apply
      // the host state a few times so a viewer who JOINS while muted / blacked
      // out / paused / bannered lands in that state.
      for (final ms in [300, 900, 1800]) {
        Timer(Duration(milliseconds: ms), () {
          if (mounted) _applyHostState();
        });
      }
    }
  }

  @override
  void didUpdateWidget(covariant LivePlayer old) {
    super.didUpdateWidget(old);
    if (old.hostMuted != widget.hostMuted || old.blank != widget.blank || old.paused != widget.paused || old.banner != widget.banner || old.slide != widget.slide) {
      _applyHostState();
    }
  }

  // Apply the host controls. Pause FREEZES the current frame (no black-out);
  // only black-out shows the opaque cover. On web these drive HTML overlays /
  // the <video> element; on mobile we pause/mute the controller and rebuild so
  // the Flutter cover reflects the state.
  void _applyHostState() {
    if (kIsWeb) {
      liveSetMuted(widget.hostMuted);
      liveSetPaused(widget.paused);
      liveSetCover(widget.blank ? 'Back shortly' : '');
      liveSetBanner(widget.banner);
      liveSetSlide(widget.slide);
    } else {
      final c = _c;
      if (c != null) {
        c.setVolume((widget.hostMuted || _muted) ? 0 : 1);
        if (widget.paused && c.value.isPlaying) {
          c.pause();
        } else if (!widget.paused && !c.value.isPlaying) {
          c.play();
          _followEdge(force: true);
        }
      }
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _c?.dispose();
    if (kIsWeb) liveDisposeInstance(_liveId); // destroy hls.js + <video> — no orphaned audio
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _c?.setVolume((_muted || widget.hostMuted) ? 0 : 1);
  }

  // Reload the stream (recover a stall) without leaving the room. Re-creates the
  // controller so it re-fetches the playlist and snaps to the live edge.
  Future<void> _reload() async {
    final old = _c;
    setState(() => _ready = false);
    await old?.dispose();
    _c = VideoPlayerController.networkUrl(
      Uri.parse(widget.playlistUrl),
      httpHeaders: widget.authToken.isNotEmpty ? {'Authorization': 'Bearer ${widget.authToken}'} : const {},
    );
    try {
      await _c!.initialize();
      _c!.play();
      _followEdge(force: true);
      _applyHostState();
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not reload the live stream.');
    }
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
        child: liveHlsVideoElement(widget.playlistUrl, authToken: widget.authToken, startEpochMs: widget.startEpochMs, skewMs: widget.skewMs, title: widget.title, course: widget.course, instanceId: _liveId),
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
            _ctlBtn(CupertinoIcons.arrow_clockwise, _reload),
            const SizedBox(width: 6),
            _ctlBtn(_muted ? CupertinoIcons.volume_off : CupertinoIcons.volume_up, _toggleMute),
            const SizedBox(width: 6),
            _ctlBtn(_fullscreen ? CupertinoIcons.fullscreen_exit : CupertinoIcons.fullscreen, _toggleFullscreen),
          ]),
        ),
        // Host pinned banner.
        if (widget.banner.isNotEmpty)
          Positioned(top: 0, left: 0, right: 0, child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            color: const Color(0xFFFF4F2B).withValues(alpha: 0.94),
            child: Text(widget.banner, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
          )),
        // (The presented slide is drawn by the live room over the whole stage.)
        // Pause freezes the frame with no overlay — the viewer just sees the
        // last frame (video is paused in _applyHostState).
        // Black-out cover (opaque).
        if (widget.blank)
          Positioned.fill(child: Container(
            color: Colors.black.withValues(alpha: 0.985),
            alignment: Alignment.center,
            child: const Text('Back shortly', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
          )),
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
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), borderRadius: BorderRadius.zero),
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
