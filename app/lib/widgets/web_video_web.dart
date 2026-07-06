// Web video element with hls.js for HLS (.m3u8) streaming. mp4 plays via the
// native <video>; .m3u8 is streamed by hls.js (Chrome/Firefox) or natively
// (Safari). The native browser controls are removed — playback is driven by a
// custom Netflix-style control bar that fades in on hover + keyboard shortcuts.
// Download/right-click are disabled; the watermark sits on top.
import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:math' as math;
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

// Clean (no-emoji) Netflix-style icons — Material Design 24×24 paths.
const _icPlay = 'M8 5v14l11-7z';
const _icPause = 'M6 19h4V5H6v14zm8-14v14h4V5h-4z';
const _icReplay = 'M12 5V1L7 6l5 5V7c3.31 0 6 2.69 6 6s-2.69 6-6 6-6-2.69-6-6H4c0 4.42 3.58 8 8 8s8-3.58 8-8-3.58-8-8-8z';
const _icForward = 'M12 5V1l5 5-5 5V7c-3.31 0-6 2.69-6 6s2.69 6 6 6 6-2.69 6-6h2c0 4.42-3.58 8-8 8s-8-3.58-8-8 3.58-8 8-8z';
const _icVolUp = 'M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z';
const _icVolOff = 'M16.5 12c0-1.77-1.02-3.29-2.5-4.03v2.21l2.45 2.45c.03-.2.05-.41.05-.63zm2.5 0c0 .94-.2 1.82-.54 2.64l1.51 1.51C20.63 14.91 21 13.5 21 12c0-4.28-2.99-7.86-7-8.77v2.06c2.89.86 5 3.54 5 6.71zM4.27 3L3 4.27 7.73 9H3v6h4l5 5v-6.73l4.25 4.25c-.67.52-1.42.93-2.25 1.18v2.06c1.38-.31 2.63-.95 3.69-1.81L19.73 21 21 19.73l-9-9L4.27 3zM12 4L9.91 6.09 12 8.18V4z';
const _icFullscreen = 'M7 14H5v5h5v-2H7v-3zm-2-4h2V7h3V5H5v5zm12 7h-3v2h5v-5h-2v3zM14 5v2h3v3h2V5h-5z';

// Build a fresh white SVG icon (each call returns a new element). Built with
// createElementNS so it works without the (removed) dart:svg library.
const _svgNs = 'http://www.w3.org/2000/svg';
html.Element _vicon(String path, {double size = 22}) {
  final s = html.document.createElementNS(_svgNs, 'svg')
    ..setAttribute('viewBox', '0 0 24 24')
    ..setAttribute('width', size.toString())
    ..setAttribute('height', size.toString())
    ..setAttribute('fill', 'white');
  s.append(html.document.createElementNS(_svgNs, 'path')..setAttribute('d', path));
  return s;
}

// Each open registers a fresh view factory so [startAt]/callbacks are current
// (factories are cached by view type, so we use a unique type per open).
int _seq = 0;

// Only one player is on screen at a time; keep a single global key listener and
// cancel the previous one whenever a new player mounts.
StreamSubscription<html.KeyboardEvent>? _keySub;

// Live-stream stall watchdog (one player on screen at a time).
Timer? _liveGuardTimer;

const _accent = '#FF4F2B';
const _speeds = [0.5, 1.0, 1.25, 1.5, 2.0];

String _fmt(double secs) {
  if (!secs.isFinite || secs.isNaN || secs < 0) secs = 0;
  final s = secs.floor();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '$m:${two(sec)}';
}

Widget hlsVideoElement(
  String url, {
  String authToken = '',
  double startAt = 0,
  bool autoPlay = true,
  void Function(double position, double duration)? onTime,
  void Function()? onEnded,
}) {
  final viewType = 'onrol-video-${_seq++}';
  ui_web.platformViewRegistry.registerViewFactory(viewType, (int id) {
    final video = html.VideoElement()
      ..controls = false // ← no native browser controls
      ..autoplay = autoPlay
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.display = 'block'
      ..style.backgroundColor = 'black'
      ..setAttribute('controlsList', 'nodownload noplaybackrate noremoteplayback')
      ..setAttribute('playsinline', 'true')
      ..setAttribute('disablePictureInPicture', 'true');

    // Wrapper so the control bar + badge can overlay the video and the whole
    // player can go fullscreen as one unit.
    final container = html.DivElement()
      ..style.position = 'relative'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.background = 'black'
      ..style.overflow = 'hidden'
      ..style.outline = 'none'
      ..tabIndex = 0;

    // Centre feedback badge (clean icons + text, no emojis) — fades out.
    final badge = html.DivElement()
      ..style.position = 'absolute'
      ..style.top = '50%'
      ..style.left = '50%'
      ..style.transform = 'translate(-50%, -50%)'
      ..style.padding = '14px 20px'
      ..style.background = 'rgba(0,0,0,0.55)'
      ..style.color = 'white'
      ..style.borderRadius = '16px'
      ..style.display = 'flex'
      ..style.alignItems = 'center'
      ..style.gap = '8px'
      ..style.font = '600 20px -apple-system, Segoe UI, Roboto, sans-serif'
      ..style.pointerEvents = 'none'
      ..style.opacity = '0'
      ..style.transition = 'opacity 0.22s ease'
      ..style.zIndex = '8';

    container.append(video);
    container.append(badge);

    // Deter right-click "Save video as…". (Not real protection — browsers can't
    // block screen recording; that needs DRM. The watermark is the deterrent.)
    video.onContextMenu.listen((e) => e.preventDefault());

    double clamp(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);
    double durOf() {
      final d = video.duration;
      return (d.isFinite && !d.isNaN) ? d.toDouble() : 0.0;
    }

    // ---- Feedback badge -----------------------------------------------------
    Timer? badgeTimer;
    void showBadge() {
      badge.style.opacity = '1';
      badgeTimer?.cancel();
      badgeTimer = Timer(const Duration(milliseconds: 560), () => badge.style.opacity = '0');
    }

    // Plain-text flash (play/pause symbols, %, speed) — no emojis.
    void flash(String text) {
      badge.text = text;
      showBadge();
    }

    // Icon (+ optional label) flash — clean SVG, Netflix-style.
    void flashIcon(html.Element ic, [String? label]) {
      badge.children.clear();
      badge.append(ic);
      if (label != null) badge.append(html.SpanElement()..text = label);
      showBadge();
    }

    // ===================== Control bar =======================================
    final controls = html.DivElement()
      ..style.position = 'absolute'
      ..style.left = '0'
      ..style.right = '0'
      ..style.bottom = '0'
      ..style.padding = '34px 20px 16px'
      ..style.boxSizing = 'border-box'
      ..style.display = 'flex'
      ..style.flexDirection = 'column'
      ..style.gap = '6px'
      ..style.background = 'linear-gradient(to top, rgba(0,0,0,0.78), rgba(0,0,0,0))'
      ..style.opacity = '1'
      ..style.transition = 'opacity 0.25s ease'
      ..style.zIndex = '7'
      ..style.font = '500 15px -apple-system, Segoe UI, Roboto, sans-serif';

    // Seek scrubber (0..1000 for fine granularity).
    final seek = html.RangeInputElement()
      ..min = '0'
      ..max = '1000'
      ..value = '0'
      ..style.width = '100%'
      ..style.cursor = 'pointer'
      ..style.height = '22px';
    seek.style.setProperty('accent-color', _accent);

    // Button factory.
    html.SpanElement btn(String label, void Function() onTap, {double size = 15}) {
      final b = html.SpanElement()
        ..text = label
        ..style.cursor = 'pointer'
        ..style.padding = '7px 11px'
        ..style.borderRadius = '8px'
        ..style.color = 'white'
        ..style.userSelect = 'none'
        ..style.fontSize = '${size}px'
        ..style.lineHeight = '1'
        ..style.transition = 'background 0.15s ease';
      b.onClick.listen((e) {
        e.stopPropagation();
        onTap();
      });
      b.onMouseEnter.listen((_) => b.style.background = 'rgba(255,255,255,0.16)');
      b.onMouseLeave.listen((_) => b.style.background = 'transparent');
      return b;
    }

    // ---- Transport actions (shared by buttons + keyboard) -------------------
    void togglePlay() {
      if (video.paused) {
        video.play();
        flashIcon(_vicon(_icPlay, size: 30));
      } else {
        video.pause();
        flashIcon(_vicon(_icPause, size: 30));
      }
    }

    void seekBy(int seconds) {
      final d = durOf();
      video.currentTime = clamp(video.currentTime.toDouble() + seconds, 0, d > 0 ? d : double.infinity);
      flashIcon(_vicon(seconds > 0 ? _icForward : _icReplay, size: 30), '${seconds.abs()}s');
    }

    void changeVolume(double delta) {
      video.muted = false;
      video.volume = clamp(video.volume.toDouble() + delta, 0, 1);
      flashIcon(_vicon(_icVolUp, size: 26), '${(video.volume * 100).round()}%');
    }

    void toggleFullscreen() {
      if (html.document.fullscreenElement != null) {
        html.document.exitFullscreen();
      } else {
        container.requestFullscreen();
      }
    }

    void jumpToFraction(double f) {
      final d = durOf();
      if (d > 0) {
        video.currentTime = d * clamp(f, 0, 1);
        flash('${(f * 100).round()}%');
      }
    }

    // YouTube-style large center play/pause button (tap target on top of video).
    final centerBtn = html.DivElement()
      ..style.position = 'absolute'
      ..style.top = '50%'
      ..style.left = '50%'
      ..style.transform = 'translate(-50%, -50%)'
      ..style.width = '88px'
      ..style.height = '88px'
      ..style.borderRadius = '50%'
      ..style.background = 'rgba(0,0,0,0.5)'
      ..style.display = 'flex'
      ..style.alignItems = 'center'
      ..style.justifyContent = 'center'
      ..style.cursor = 'pointer'
      ..style.zIndex = '9'
      ..style.transition = 'opacity 0.2s ease';
    centerBtn.append(_vicon(_icPlay, size: 46));
    centerBtn.onClick.listen((e) {
      e.stopPropagation();
      togglePlay();
    });
    void showCenter(String icon) {
      centerBtn.children.clear();
      centerBtn.append(_vicon(icon, size: 46));
      centerBtn.style.opacity = '1';
      centerBtn.style.pointerEvents = 'auto';
    }
    void hideCenter() {
      centerBtn.style.opacity = '0';
      centerBtn.style.pointerEvents = 'none';
    }
    container.append(centerBtn);
    // Autoplay starts playing (button revealed on pause/end); otherwise the
    // video waits paused and shows the big play button so the user starts it.
    if (autoPlay) { hideCenter(); } else { showCenter(_icPlay); }

    // Icon-button factory (clean SVG, no emojis).
    html.SpanElement iconBtn(String path, void Function() onTap, {double size = 22}) {
      final b = html.SpanElement()
        ..style.cursor = 'pointer'
        ..style.padding = '8px 10px'
        ..style.borderRadius = '8px'
        ..style.display = 'flex'
        ..style.alignItems = 'center'
        ..style.lineHeight = '0'
        ..style.transition = 'background 0.15s ease';
      b.append(_vicon(path, size: size));
      b.onClick.listen((e) {
        e.stopPropagation();
        onTap();
      });
      b.onMouseEnter.listen((_) => b.style.background = 'rgba(255,255,255,0.16)');
      b.onMouseLeave.listen((_) => b.style.background = 'transparent');
      return b;
    }

    void setBtnIcon(html.SpanElement b, String path, {double size = 22}) {
      b.children.clear();
      b.append(_vicon(path, size: size));
    }

    // Buttons.
    final playBtn = iconBtn(_icPlay, togglePlay, size: 34);
    final back10 = iconBtn(_icReplay, () => seekBy(-10), size: 30);
    final fwd10 = iconBtn(_icForward, () => seekBy(10), size: 30);
    final timeLabel = html.SpanElement()
      ..text = '0:00 / 0:00'
      ..style.color = 'white'
      ..style.fontSize = '15px'
      ..style.fontWeight = '600'
      ..style.padding = '0 8px'
      ..style.whiteSpace = 'nowrap';

    final speedBtn = btn('1×', () {}, size: 17);
    var speedIdx = 1;
    speedBtn.onClick.listen((e) {
      e.stopPropagation();
      speedIdx = (speedIdx + 1) % _speeds.length;
      video.playbackRate = _speeds[speedIdx];
      final sp = _speeds[speedIdx];
      speedBtn.text = '${sp == sp.roundToDouble() ? sp.toInt() : sp}×';
      flash('${speedBtn.text}');
    });

    final muteBtn = iconBtn(_icVolUp, () {}, size: 28);
    void refreshMute() => setBtnIcon(muteBtn, (video.muted || video.volume == 0) ? _icVolOff : _icVolUp, size: 28);
    muteBtn.onClick.listen((e) {
      e.stopPropagation();
      video.muted = !video.muted;
      refreshMute();
      flashIcon(_vicon(video.muted ? _icVolOff : _icVolUp, size: 26));
    });

    final volRange = html.RangeInputElement()
      ..min = '0'
      ..max = '100'
      ..value = '100'
      ..style.width = '92px'
      ..style.cursor = 'pointer'
      ..style.height = '18px';
    volRange.style.setProperty('accent-color', _accent);
    volRange.onInput.listen((e) {
      e.stopPropagation();
      video.muted = false;
      video.volume = (double.tryParse(volRange.value ?? '100') ?? 100) / 100;
      refreshMute();
    });

    final fsBtn = iconBtn(_icFullscreen, toggleFullscreen, size: 30);

    final spacer = html.DivElement()..style.flex = '1';
    final row = html.DivElement()
      ..style.display = 'flex'
      ..style.alignItems = 'center'
      ..style.gap = '8px';
    row.append(playBtn);
    row.append(back10);
    row.append(fwd10);
    row.append(timeLabel);
    row.append(spacer);
    row.append(speedBtn);
    row.append(muteBtn);
    row.append(volRange);
    row.append(fsBtn);

    controls.append(seek);
    controls.append(row);
    container.append(controls);

    // Keep clicks on the control bar from reaching the video (which toggles play).
    controls.onClick.listen((e) => e.stopPropagation());

    // ---- Scrubber wiring ----------------------------------------------------
    var dragging = false;
    seek.onInput.listen((e) {
      e.stopPropagation();
      dragging = true;
      final d = durOf();
      final t = (double.tryParse(seek.value ?? '0') ?? 0) / 1000 * d;
      timeLabel.text = '${_fmt(t)} / ${_fmt(d)}';
    });
    seek.onChange.listen((e) {
      e.stopPropagation();
      final d = durOf();
      if (d > 0) video.currentTime = (double.tryParse(seek.value ?? '0') ?? 0) / 1000 * d;
      dragging = false;
    });

    // ---- Play/pause icon sync ----------------------------------------------
    video.onPlay.listen((_) {
      setBtnIcon(playBtn, _icPause, size: 34);
      hideCenter();
    });
    video.onPause.listen((_) {
      setBtnIcon(playBtn, _icPlay, size: 34);
      showCenter(_icPlay);
    });
    video.onEnded.listen((_) => showCenter(_icReplay));

    // ---- Auto-hide on inactivity (Netflix style) ---------------------------
    Timer? hideTimer;
    void showControls() {
      controls.style.opacity = '1';
      container.style.cursor = 'default';
      hideTimer?.cancel();
      hideTimer = Timer(const Duration(milliseconds: 2600), () {
        if (!video.paused && !dragging) {
          controls.style.opacity = '0';
          container.style.cursor = 'none';
        }
      });
    }

    container.onMouseMove.listen((_) => showControls());
    container.onMouseEnter.listen((_) => showControls());
    container.onMouseLeave.listen((_) {
      if (!video.paused && !dragging) controls.style.opacity = '0';
    });
    // When paused, always show the controls.
    video.onPause.listen((_) {
      hideTimer?.cancel();
      controls.style.opacity = '1';
      container.style.cursor = 'default';
    });

    // ---- Tap on the video toggles the CONTROLS — it never plays/pauses.
    // Playback only starts from "Continue" (which opens the player) or the
    // explicit play button / keyboard. Double-click toggles fullscreen.
    video.onClick.listen((_) {
      if (controls.style.opacity == '0') {
        showControls();
      } else {
        controls.style.opacity = '0';
        if (!video.paused) container.style.cursor = 'none';
      }
    });
    video.onDoubleClick.listen((e) {
      e.preventDefault();
      toggleFullscreen();
    });

    // ---- Keyboard (Netflix-style) -------------------------------------------
    _keySub?.cancel();
    _keySub = html.document.onKeyDown.listen((e) {
      if (container.isConnected != true) return;
      final target = e.target;
      if (target is html.InputElement || target is html.TextAreaElement) return;
      final k = e.key;
      if (k == null) return;
      showControls();
      switch (k) {
        case ' ':
        case 'k':
        case 'K':
          e.preventDefault();
          togglePlay();
          break;
        case 'ArrowRight':
          e.preventDefault();
          seekBy(10);
          break;
        case 'ArrowLeft':
          e.preventDefault();
          seekBy(-10);
          break;
        case 'l':
        case 'L':
          seekBy(10);
          break;
        case 'j':
        case 'J':
          seekBy(-10);
          break;
        case 'ArrowUp':
          e.preventDefault();
          changeVolume(0.1);
          break;
        case 'ArrowDown':
          e.preventDefault();
          changeVolume(-0.1);
          break;
        case 'm':
        case 'M':
          video.muted = !video.muted;
          refreshMute();
          flashIcon(_vicon(video.muted ? _icVolOff : _icVolUp, size: 26));
          break;
        case 'f':
        case 'F':
          e.preventDefault();
          toggleFullscreen();
          break;
        default:
          final n = int.tryParse(k);
          if (n != null && n >= 0 && n <= 9) {
            e.preventDefault();
            jumpToFraction(n / 10);
          }
      }
    });

    // Resume: seek to the saved position once metadata is available.
    video.onLoadedMetadata.listen((_) {
      if (startAt > 0) {
        try {
          video.currentTime = startAt;
        } catch (_) {}
      }
      timeLabel.text = '${_fmt(video.currentTime.toDouble())} / ${_fmt(durOf())}';
    });

    // ---- Position reporting + UI sync (drives label, scrubber) --------------
    video.onTimeUpdate.listen((_) {
      final d = durOf();
      final pos = video.currentTime.toDouble();
      if (!dragging) {
        if (d > 0) seek.value = (math.min(pos / d, 1.0) * 1000).round().toString();
        timeLabel.text = '${_fmt(pos)} / ${_fmt(d)}';
      }
      onTime?.call(pos, d);
    });
    if (onEnded != null) {
      video.onEnded.listen((_) => onEnded());
    }

    final isHls = url.toLowerCase().contains('.m3u8');
    final hlsAvailable = js.context.hasProperty('Hls');
    if (isHls && hlsAvailable && (js.context['Hls'].callMethod('isSupported') as bool? ?? false)) {
      // Stream HLS via hls.js (Chrome/Firefox/Safari-desktop). For AES-128
      // encrypted streams, attach the JWT to the key request only (same-origin
      // API) — never to the cross-origin R2 segments. xhrSetup is built by a small
      // JS helper in index.html (avoids Dart<->JS interop callback plumbing).
      final config = js.JsObject.jsify(<String, dynamic>{});
      if (authToken.isNotEmpty && js.context.hasProperty('onrolKeyXhrSetup')) {
        config['xhrSetup'] = js.context.callMethod('onrolKeyXhrSetup', [authToken]);
      }
      final hls = js.JsObject(js.context['Hls'] as js.JsFunction, [config]);
      hls.callMethod('loadSource', [url]);
      hls.callMethod('attachMedia', [video]);
    } else {
      // mp4, or HLS on Safari (native support).
      video.src = url;
    }
    return container;
  });
  return HtmlElementView(viewType: viewType);
}

// Inject the pulsing-dot keyframes once (used by the LIVE badge).
bool _livePulseInjected = false;
void _ensureLivePulse() {
  if (_livePulseInjected) return;
  _livePulseInjected = true;
  html.document.head?.append(
    html.StyleElement()..text = '@keyframes onrolLivePulse{0%,100%{opacity:1}50%{opacity:0.3}}',
  );
}

/// Stripped-down player for a simulated-live session. Playback position is pinned
/// to WALL-CLOCK TIME since the scheduled start (startEpochMs): on load it seeks
/// to (now - start), and if it ever falls behind (buffering) it SKIPS forward to
/// the current time instead of playing the missed part — so every second of the
/// video lines up with every real second, and all viewers see the same frame.
/// skewMs corrects the device clock against the server. No scrubber/seek/speed
/// controls; only mute + fullscreen. Starts muted (browsers block unmuted autoplay).
Widget liveHlsVideoElement(
  String url, {
  String authToken = '',
  int startEpochMs = 0,
  int skewMs = 0,
}) {
  final viewType = 'onrol-live-${_seq++}';
  ui_web.platformViewRegistry.registerViewFactory(viewType, (int id) {
    _ensureLivePulse();
    final video = html.VideoElement()
      ..controls = false
      ..autoplay = true
      ..muted = true
      ..tabIndex = -1 // not keyboard-focusable → no space/arrow seek or pause
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.display = 'block'
      ..style.backgroundColor = 'black'
      ..setAttribute('controlsList', 'nodownload noplaybackrate noremoteplayback')
      ..setAttribute('playsinline', 'true')
      ..setAttribute('disablePictureInPicture', 'true')
      ..setAttribute('disableRemotePlayback', 'true'); // no cast/AirPlay handoff

    final container = html.DivElement()
      ..style.position = 'relative'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.background = 'black'
      ..style.overflow = 'hidden';
    container.append(video);
    video.onContextMenu.listen((e) => e.preventDefault());
    // Swallow any keyboard event that reaches the element (space/arrows/media
    // keys) so there is no keyboard seek/pause path either.
    video.onKeyDown.listen((e) => e.preventDefault());

    // ---- LIVE badge (top-left) ----------------------------------------------
    final dot = html.DivElement()
      ..style.width = '8px'
      ..style.height = '8px'
      ..style.borderRadius = '50%'
      ..style.background = '#FF3B30'
      ..style.boxShadow = '0 0 6px #FF3B30'
      ..style.animation = 'onrolLivePulse 1.4s ease-in-out infinite';
    final livePill = html.DivElement()
      ..style.position = 'absolute'
      ..style.top = '12px'
      ..style.left = '12px'
      ..style.display = 'flex'
      ..style.alignItems = 'center'
      ..style.gap = '7px'
      ..style.padding = '5px 10px'
      ..style.borderRadius = '6px'
      ..style.background = 'rgba(0,0,0,0.5)'
      ..style.color = 'white'
      ..style.zIndex = '7'
      ..style.font = '700 12px -apple-system, Segoe UI, Roboto, sans-serif'
      ..style.letterSpacing = '0.6px';
    livePill.append(dot);
    livePill.append(html.SpanElement()..text = 'LIVE');
    container.append(livePill);

    // ---- Minimal controls (mute + fullscreen) -------------------------------
    html.SpanElement iconBtn(String path, void Function() onTap, {double size = 24}) {
      final b = html.SpanElement()
        ..style.cursor = 'pointer'
        ..style.padding = '8px 10px'
        ..style.borderRadius = '8px'
        ..style.display = 'flex'
        ..style.alignItems = 'center'
        ..style.lineHeight = '0'
        ..style.transition = 'background 0.15s ease';
      b.append(_vicon(path, size: size));
      b.onClick.listen((e) {
        e.stopPropagation();
        onTap();
      });
      b.onMouseEnter.listen((_) => b.style.background = 'rgba(255,255,255,0.16)');
      b.onMouseLeave.listen((_) => b.style.background = 'transparent');
      return b;
    }

    void setIcon(html.SpanElement b, String path, {double size = 24}) {
      b.children.clear();
      b.append(_vicon(path, size: size));
    }

    final muteBtn = iconBtn(_icVolOff, () {}, size: 26); // starts muted
    muteBtn.onClick.listen((e) {
      e.stopPropagation();
      video.muted = !video.muted;
      setIcon(muteBtn, video.muted ? _icVolOff : _icVolUp, size: 26);
    });

    void toggleFullscreen() {
      if (html.document.fullscreenElement != null) {
        html.document.exitFullscreen();
      } else {
        container.requestFullscreen();
      }
    }

    final fsBtn = iconBtn(_icFullscreen, toggleFullscreen, size: 26);

    final controls = html.DivElement()
      ..style.position = 'absolute'
      ..style.left = '0'
      ..style.right = '0'
      ..style.bottom = '0'
      ..style.padding = '24px 14px 12px'
      ..style.display = 'flex'
      ..style.alignItems = 'center'
      ..style.justifyContent = 'flex-end'
      ..style.gap = '6px'
      ..style.zIndex = '7'
      ..style.background = 'linear-gradient(to top, rgba(0,0,0,0.65), rgba(0,0,0,0))';
    controls.append(muteBtn);
    controls.append(fsBtn);
    controls.append(html.DivElement()..style.width = '2px');
    controls.onClick.listen((e) => e.stopPropagation());
    container.append(controls);

    // Starts muted (browsers block unmuted autoplay); keep the mute-button icon
    // in sync if the volume changes by any other means.
    video.onVolumeChange.listen((_) => setIcon(muteBtn, video.muted ? _icVolOff : _icVolUp, size: 26));

    // The source is the server's sliding-window LIVE playlist (no
    // #EXT-X-ENDLIST while live), so hls.js runs in live mode and video.duration
    // is Infinity — that is what makes the browser/OS expose NO scrubber and NO
    // forward/back seek. We deliberately do NOT pin to an absolute time (that
    // needs a finite, seekable VOD, which is exactly what brings the media-popup
    // seek bar back). Instead we let hls.js hold the live edge and only nudge
    // FORWARD to hls.liveSyncPosition when we've genuinely fallen behind (a stall
    // or a backgrounded tab); we never replay. Cross-viewer sync is handled
    // server-side: every viewer's window ends at the same wall-clock second.
    js.JsObject? hlsRef;
    void toEdge() {
      try {
        final h = hlsRef;
        final lsp = h != null ? h['liveSyncPosition'] : null;
        final want = (lsp is num) ? lsp.toDouble() : double.nan;
        if (want.isFinite && want - video.currentTime > 8) {
          try {
            video.currentTime = want;
          } catch (_) {}
        }
      } catch (_) {}
      if (video.paused && container.isConnected == true && html.document.fullscreenElement == null) {
        video.play();
      }
    }

    final isHls = url.toLowerCase().contains('.m3u8');
    final hlsAvailable = js.context.hasProperty('Hls');
    if (isHls && hlsAvailable && (js.context['Hls'].callMethod('isSupported') as bool? ?? false)) {
      // LIVE config: no back-buffer, follow the edge (~3 target durations behind
      // for stability, auto-catch-up if it drifts too far). Both the playlist AND
      // the AES key are auth-gated /api/v1/me/live/ routes, so attach the JWT to
      // every live XHR; segments are public R2 (a different path), so the token
      // never leaks to the CDN.
      final config = js.JsObject.jsify(<String, dynamic>{
        'backBufferLength': 0,
        'liveSyncDurationCount': 3,
        'liveMaxLatencyDurationCount': 10,
        'lowLatencyMode': false,
        // Report the live stream as Infinity-duration. A finite (DVR-window)
        // duration is precisely what makes the OS / browser media notification
        // draw a seek bar; with Infinity there is NO scrubber and NO seek there.
        'liveDurationInfinity': true,
      });
      if (authToken.isNotEmpty && js.context.hasProperty('onrolLiveXhrSetup')) {
        config['xhrSetup'] = js.context.callMethod('onrolLiveXhrSetup', [authToken]);
      }
      final hls = js.JsObject(js.context['Hls'] as js.JsFunction, [config]);
      hlsRef = hls;
      if (js.context.hasProperty('onrolLiveGuard')) {
        js.context.callMethod('onrolLiveGuard', [hls]);
      }
      hls.callMethod('loadSource', [url]);
      hls.callMethod('attachMedia', [video]);
    } else {
      video.src = url; // Safari plays the live HLS natively (follows the edge)
    }

    // Fully suppress the OS / browser media notification for live (no metadata,
    // and no controls that could drive the stream). Re-applied on play and every
    // second below, since the browser re-populates the session on state changes.
    void neuterMediaSession() {
      try {
        if (js.context.hasProperty('onrolNeuterMediaSession')) js.context.callMethod('onrolNeuterMediaSession');
      } catch (_) {}
    }

    video.onPlay.listen((_) => neuterMediaSession());
    video.onLoadedMetadata.listen((_) {
      neuterMediaSession();
      toEdge();
    });
    video.onCanPlay.listen((_) {
      neuterMediaSession();
      if (video.paused) video.play();
    });
    // No user-facing pause exists; if anything (tab/OS) pauses us, resume and
    // realign to the live edge.
    video.onPause.listen((_) {
      if (container.isConnected == true && html.document.fullscreenElement == null) toEdge();
    });
    html.document.onVisibilityChange.listen((_) {
      if (html.document.hidden == false) toEdge();
    });
    _liveGuardTimer?.cancel();
    _liveGuardTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (container.isConnected != true) {
        t.cancel();
        return;
      }
      neuterMediaSession(); // keep the media notification wiped while live
      if (video.paused && html.document.fullscreenElement == null && container.isConnected == true) {
        video.play();
      }
    });
    return container;
  });
  return HtmlElementView(viewType: viewType);
}
