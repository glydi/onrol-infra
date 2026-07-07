import 'dart:async';

import 'package:flutter/cupertino.dart' hide Text;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' hide Text;
import 'package:onrol_app/widgets/upper_text.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../widgets/watermark_overlay.dart';
import '../widgets/web_video_stub.dart' if (dart.library.html) '../widgets/web_video_web.dart';

/// Streaming video player with custom (Flutter-drawn) app controls — play/pause,
/// ±10s seek, scrubber, speed, mute and fullscreen. There is no native download
/// button and the per-student identity watermark is drawn on top. Recording is
/// blocked app-wide (Android FLAG_SECURE; iOS capture-blanking) and the file is
/// never offered as a download.
class VideoPlayerScreen extends StatefulWidget {
  const VideoPlayerScreen({super.key, required this.url, required this.watermark, this.title = 'Video', this.startAt = Duration.zero, this.onProgress, this.onCompleted, this.authToken = '', this.embedded = false, this.autoPlay = true});
  final String url;
  final String watermark;
  final String title;
  // JWT used to authenticate encrypted-HLS key requests (segments are AES-128).
  final String authToken;
  // Resume point + callbacks so the lesson can save position / mark complete.
  final Duration startAt;
  final void Function(Duration position, Duration duration)? onProgress;
  final VoidCallback? onCompleted;
  // When true, render just the player (no Scaffold/route chrome) so it can be
  // embedded inline — e.g. inside the material reader.
  final bool embedded;
  // When false, the video loads but waits paused (big play button) instead of
  // starting on its own.
  final bool autoPlay;

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  VideoPlayerController? _c;
  bool _ready = false;
  String? _error;
  bool _showControls = true;
  bool _fullscreen = false;
  bool _muted = false;
  double _speed = 1.0;
  Timer? _hideTimer;
  int _lastSaved = 0; // last position (s) reported, for throttling
  double? _scrub; // position (ms) while dragging the scrubber, else null
  bool _completed = false;
  bool _webHint = true; // brief keyboard-shortcuts hint on the web player
  Widget? _webVideo; // built ONCE so setState rebuilds don't recreate the
  // <video>/hls.js element (which would restart playback — "first plays twice").

  static const _speeds = [0.5, 1.0, 1.25, 1.5, 2.0];
  static const _accent = Color(0xFFFF4F2B);

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      // Fade the keyboard-shortcuts hint out after a few seconds.
      Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _webHint = false);
      });
    }
    if (!kIsWeb) {
      _c = VideoPlayerController.networkUrl(Uri.parse(widget.url),
          httpHeaders: widget.authToken.isNotEmpty ? {'Authorization': 'Bearer ${widget.authToken}'} : const {});
      _c!.initialize().then((_) async {
        if (widget.startAt.inSeconds > 0) {
          await _c!.seekTo(widget.startAt);
        }
        if (widget.autoPlay) _c!.play();
        _c!.addListener(_tick);
        if (mounted) setState(() => _ready = true);
        _scheduleHide();
      }).catchError((_) {
        if (mounted) setState(() => _error = 'Could not load this video.');
      });
    }
  }

  void _tick() {
    if (!mounted) return;
    final c = _c;
    if (c != null) _report(c.value.position, c.value.duration);
    setState(() {});
  }

  // Shared progress/completion reporting for web + mobile.
  void _report(Duration pos, Duration dur) {
    if (dur.inSeconds > 0 && !_completed && pos.inSeconds >= (dur.inSeconds * 0.95).floor()) {
      _completed = true;
      widget.onCompleted?.call();
    }
    if ((pos.inSeconds - _lastSaved).abs() >= 5) {
      _lastSaved = pos.inSeconds;
      widget.onProgress?.call(pos, dur);
    }
  }

  void _onWebTime(double position, double duration) =>
      _report(Duration(seconds: position.floor()), Duration(seconds: duration.floor()));

  @override
  void dispose() {
    _hideTimer?.cancel();
    // Save the final position so resume is exact even if the user just left.
    final c = _c;
    if (c != null && c.value.isInitialized) {
      widget.onProgress?.call(c.value.position, c.value.duration);
    }
    _c?.removeListener(_tick);
    _c?.dispose();
    // Make sure we leave fullscreen state cleanly.
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // Auto-hide the controls a few seconds after the last interaction (while playing).
  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (_c?.value.isPlaying ?? false)) setState(() => _showControls = false);
    });
  }

  void _flashControls() {
    setState(() => _showControls = true);
    _scheduleHide();
  }

  void _togglePlay() {
    final c = _c;
    if (c == null) return;
    setState(() => c.value.isPlaying ? c.pause() : c.play());
    _flashControls();
  }

  void _seekBy(int seconds) {
    final c = _c;
    if (c == null) return;
    var target = c.value.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (target > c.value.duration) target = c.value.duration;
    c.seekTo(target);
    _flashControls();
  }

  void _cycleSpeed() {
    final i = (_speeds.indexOf(_speed) + 1) % _speeds.length;
    setState(() => _speed = _speeds[i]);
    _c?.setPlaybackSpeed(_speed);
    _flashControls();
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _c?.setVolume(_muted ? 0 : 1);
    _flashControls();
  }

  Future<void> _toggleFullscreen() async {
    setState(() => _fullscreen = !_fullscreen);
    if (_fullscreen) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations(
          [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
    _flashControls();
  }

  @override
  Widget build(BuildContext context) {
    final player = WatermarkOverlay(
      label: widget.watermark,
      child: kIsWeb ? _webPlayer() : _mobilePlayer(),
    );
    // Embedded (inside the material reader): no Scaffold/route chrome.
    if (widget.embedded) {
      return ColoredBox(color: const Color(0xFF0B0B0D), child: player);
    }
    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _fullscreen) _toggleFullscreen();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B0B0D),
        body: _fullscreen
            ? Center(child: player)
            : Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1100),
                    child: ClipRRect(borderRadius: BorderRadius.zero, child: player),
                  ),
                ),
              ),
      ),
    );
  }

  // Web: hls.js-backed <video> with NO native browser controls. Playback is
  // driven by Netflix-style keyboard shortcuts + click (handled in the platform
  // view); a floating top bar and a brief shortcuts hint overlay on top.
  Widget _webPlayer() => Stack(children: [
        _webVideo ??= AspectRatio(
          aspectRatio: 16 / 9,
          child: hlsVideoElement(widget.url, authToken: widget.authToken, startAt: widget.startAt.inSeconds.toDouble(), autoPlay: widget.autoPlay, onTime: _onWebTime, onEnded: () {
            if (!_completed) {
              _completed = true;
              widget.onCompleted?.call();
            }
          }),
        ),
        _topBar(),
        // Auto-fading keyboard-shortcuts hint (sits above the control bar).
        Positioned(
          left: 0, right: 0, bottom: 80,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _webHint ? 1 : 0,
              duration: const Duration(milliseconds: 400),
              child: Center(child: _shortcutsHint()),
            ),
          ),
        ),
      ]);

  Widget _shortcutsHint() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(color: Colors.black.withOpacity(0.55), borderRadius: BorderRadius.zero),
        child: Wrap(
          spacing: 14, runSpacing: 6, alignment: WrapAlignment.center,
          children: const [
            _HintChip('Space', 'Play / Pause'),
            _HintChip('← →', 'Seek 10s'),
            _HintChip('↑ ↓', 'Volume'),
            _HintChip('M', 'Mute'),
            _HintChip('F', 'Fullscreen'),
            _HintChip('0–9', 'Jump'),
          ],
        ),
      );

  // Mobile: video_player with custom app controls.
  Widget _mobilePlayer() {
    if (_error != null) {
      return AspectRatio(aspectRatio: 16 / 9, child: Center(child: Text(_error!, style: const TextStyle(color: Colors.white70))));
    }
    if (!_ready || _c == null) {
      return const AspectRatio(aspectRatio: 16 / 9, child: Center(child: CupertinoActivityIndicator(color: Colors.white, radius: 14)));
    }
    final c = _c!;
    final ar = c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio;
    final video = GestureDetector(
      onTap: () {
        if (_showControls) {
          setState(() => _showControls = false);
          _hideTimer?.cancel();
        } else {
          _flashControls();
        }
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          VideoPlayer(c),
          if (c.value.isBuffering) const CupertinoActivityIndicator(color: Colors.white, radius: 16),
          AnimatedOpacity(
            opacity: _showControls ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: IgnorePointer(ignoring: !_showControls, child: _controls()),
          ),
        ],
      ),
    );
    // In fullscreen, fill the screen; otherwise keep the natural aspect ratio.
    return _fullscreen ? SizedBox.expand(child: FittedBox(fit: BoxFit.contain, child: SizedBox(width: ar * 1000, height: 1000, child: video))) : AspectRatio(aspectRatio: ar, child: video);
  }

  Widget _topBar() {
    if (widget.embedded) return const SizedBox.shrink(); // reader supplies its own header
    return Positioned(
      top: 0, left: 0, right: 0,
      child: SafeArea(
        // Only inset for the notch / Dynamic Island in fullscreen, where the
        // video meets the screen top. Embedded, the player is a 16:9 box centred
        // mid-screen, so a top inset would shove the title down off its top edge.
        top: _fullscreen,
        bottom: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(4, 4, 12, 20),
          decoration: const BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xB3000000), Color(0x00000000)]),
          ),
          child: Row(children: [
            IconButton(
              icon: const Icon(CupertinoIcons.chevron_back, color: Colors.white, size: 26),
              onPressed: () {
                if (_fullscreen) {
                  _toggleFullscreen();
                } else {
                  Navigator.pop(context);
                }
              },
            ),
            Expanded(
              child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _controls() {
    final c = _c!;
    final playing = c.value.isPlaying;
    return Stack(
      children: [
        Container(color: Colors.black38),
        _topBar(),
        // Center transport: -10s, play/pause, +10s.
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _roundBtn(CupertinoIcons.gobackward_10, () => _seekBy(-10), size: 26, pad: 12),
              const SizedBox(width: 28),
              GestureDetector(
                onTap: _togglePlay,
                child: Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(color: _accent.withOpacity(0.92), shape: BoxShape.circle, boxShadow: [BoxShadow(color: _accent.withOpacity(0.5), blurRadius: 18)]),
                  child: Icon(playing ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill, color: Colors.white, size: 34),
                ),
              ),
              const SizedBox(width: 28),
              _roundBtn(CupertinoIcons.goforward_10, () => _seekBy(10), size: 26, pad: 12),
            ],
          ),
        ),
        // Bottom bar: scrubber, times, speed, mute, fullscreen.
        Positioned(
          left: 12, right: 12, bottom: 10,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Draggable scrubber with a visible thumb + generous touch target
              // (the thin default indicator was hard to grab on a phone).
              Builder(builder: (_) {
                final durMs = c.value.duration.inMilliseconds.toDouble();
                final maxMs = durMs <= 0 ? 1.0 : durMs;
                final posMs = (_scrub ?? c.value.position.inMilliseconds.toDouble()).clamp(0.0, maxMs);
                return SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    activeTrackColor: _accent,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7, elevation: 2),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                    overlayColor: _accent.withOpacity(0.3),
                    trackShape: const RoundedRectSliderTrackShape(),
                  ),
                  child: Slider(
                    value: posMs,
                    max: maxMs,
                    onChangeStart: (_) => _hideTimer?.cancel(),
                    onChanged: (v) => setState(() => _scrub = v),
                    onChangeEnd: (v) {
                      _c?.seekTo(Duration(milliseconds: v.round()));
                      setState(() => _scrub = null);
                      _flashControls();
                    },
                  ),
                );
              }),
              Row(
                children: [
                  Text(_fmt(_scrub != null ? Duration(milliseconds: _scrub!.round()) : c.value.position), style: const TextStyle(color: Colors.white, fontSize: 12)),
                  const Text('  /  ', style: TextStyle(color: Colors.white38, fontSize: 12)),
                  Text(_fmt(c.value.duration), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  const Spacer(),
                  GestureDetector(
                    onTap: _cycleSpeed,
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Text('${_speed == _speed.roundToDouble() ? _speed.toInt() : _speed}×',
                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                  ),
                  _roundBtn(_muted ? CupertinoIcons.volume_off : CupertinoIcons.volume_up, _toggleMute, size: 20, pad: 6),
                  const SizedBox(width: 4),
                  _roundBtn(_fullscreen ? CupertinoIcons.fullscreen_exit : CupertinoIcons.fullscreen, _toggleFullscreen, size: 20, pad: 6),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _roundBtn(IconData icon, VoidCallback onTap, {double size = 22, double pad = 8}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.all(pad),
        decoration: const BoxDecoration(color: Color(0x33FFFFFF), shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: size),
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

/// One key + action pill in the web keyboard-shortcuts hint.
class _HintChip extends StatelessWidget {
  const _HintChip(this.keys, this.label);
  final String keys;
  final String label;
  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(color: Colors.white.withOpacity(0.18), borderRadius: BorderRadius.zero),
        child: Text(keys, style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700)),
      ),
      const SizedBox(width: 5),
      Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w500)),
    ]);
  }
}
