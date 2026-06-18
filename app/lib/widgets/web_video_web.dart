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

// Each open registers a fresh view factory so [startAt]/callbacks are current
// (factories are cached by view type, so we use a unique type per open).
int _seq = 0;

// Only one player is on screen at a time; keep a single global key listener and
// cancel the previous one whenever a new player mounts.
StreamSubscription<html.KeyboardEvent>? _keySub;

const _accent = '#FF4F2B';
const _speeds = [0.5, 1.0, 1.25, 1.5, 2.0];

String _fmt(double secs) {
  if (!secs.isFinite || secs.isNaN || secs < 0) secs = 0;
  final s = secs.floor();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${m}:${two(sec)}';
}

Widget hlsVideoElement(
  String url, {
  String authToken = '',
  double startAt = 0,
  void Function(double position, double duration)? onTime,
  void Function()? onEnded,
}) {
  final viewType = 'onrol-video-${_seq++}';
  ui_web.platformViewRegistry.registerViewFactory(viewType, (int id) {
    final video = html.VideoElement()
      ..controls = false // ← no native browser controls
      ..autoplay = true
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

    // Centre feedback badge (▶ / ❚❚ / ⏩ 10s / 🔊 80% …) — fades out.
    final badge = html.DivElement()
      ..style.position = 'absolute'
      ..style.top = '50%'
      ..style.left = '50%'
      ..style.transform = 'translate(-50%, -50%)'
      ..style.padding = '14px 20px'
      ..style.background = 'rgba(0,0,0,0.55)'
      ..style.color = 'white'
      ..style.borderRadius = '16px'
      ..style.font = '600 22px -apple-system, Segoe UI, Roboto, sans-serif'
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
    void flash(String text) {
      badge.text = text;
      badge.style.opacity = '1';
      badgeTimer?.cancel();
      badgeTimer = Timer(const Duration(milliseconds: 560), () => badge.style.opacity = '0');
    }

    // ===================== Control bar =======================================
    final controls = html.DivElement()
      ..style.position = 'absolute'
      ..style.left = '0'
      ..style.right = '0'
      ..style.bottom = '0'
      ..style.padding = '20px 14px 10px'
      ..style.boxSizing = 'border-box'
      ..style.display = 'flex'
      ..style.flexDirection = 'column'
      ..style.gap = '4px'
      ..style.background = 'linear-gradient(to top, rgba(0,0,0,0.75), rgba(0,0,0,0))'
      ..style.opacity = '1'
      ..style.transition = 'opacity 0.25s ease'
      ..style.zIndex = '7'
      ..style.font = '500 13px -apple-system, Segoe UI, Roboto, sans-serif';

    // Seek scrubber (0..1000 for fine granularity).
    final seek = html.RangeInputElement()
      ..min = '0'
      ..max = '1000'
      ..value = '0'
      ..style.width = '100%'
      ..style.cursor = 'pointer'
      ..style.height = '16px';
    seek.style.setProperty('accent-color', _accent);

    // Button factory.
    html.SpanElement btn(String label, void Function() onTap, {double size = 15}) {
      final b = html.SpanElement()
        ..text = label
        ..style.cursor = 'pointer'
        ..style.padding = '5px 8px'
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
        flash('▶');
      } else {
        video.pause();
        flash('❚❚');
      }
    }

    void seekBy(int seconds) {
      final d = durOf();
      video.currentTime = clamp(video.currentTime.toDouble() + seconds, 0, d > 0 ? d : double.infinity);
      flash(seconds > 0 ? '⏩ ${seconds}s' : '⏪ ${seconds.abs()}s');
    }

    void changeVolume(double delta) {
      video.muted = false;
      video.volume = clamp(video.volume.toDouble() + delta, 0, 1);
      flash('🔊 ${(video.volume * 100).round()}%');
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

    // Buttons.
    final playBtn = btn('►', togglePlay, size: 17);
    final back10 = btn('⟲', () => seekBy(-10), size: 17);
    final fwd10 = btn('⟳', () => seekBy(10), size: 17);
    final timeLabel = html.SpanElement()
      ..text = '0:00 / 0:00'
      ..style.color = 'white'
      ..style.fontSize = '12.5px'
      ..style.padding = '0 6px'
      ..style.whiteSpace = 'nowrap';

    final speedBtn = btn('1×', () {}, size: 13);
    var speedIdx = 1;
    speedBtn.onClick.listen((e) {
      e.stopPropagation();
      speedIdx = (speedIdx + 1) % _speeds.length;
      video.playbackRate = _speeds[speedIdx];
      final sp = _speeds[speedIdx];
      speedBtn.text = '${sp == sp.roundToDouble() ? sp.toInt() : sp}×';
      flash('${speedBtn.text}');
    });

    final muteBtn = btn('🔊', () {
      video.muted = !video.muted;
      flash(video.muted ? '🔇' : '🔊');
    }, size: 14);
    void refreshMute() => muteBtn.text = (video.muted || video.volume == 0) ? '🔇' : '🔊';

    final volRange = html.RangeInputElement()
      ..min = '0'
      ..max = '100'
      ..value = '100'
      ..style.width = '78px'
      ..style.cursor = 'pointer'
      ..style.height = '14px';
    volRange.style.setProperty('accent-color', _accent);
    volRange.onInput.listen((e) {
      e.stopPropagation();
      video.muted = false;
      video.volume = (double.tryParse(volRange.value ?? '100') ?? 100) / 100;
      refreshMute();
    });

    final fsBtn = btn('⛶', toggleFullscreen, size: 17);

    final spacer = html.DivElement()..style.flex = '1';
    final row = html.DivElement()
      ..style.display = 'flex'
      ..style.alignItems = 'center'
      ..style.gap = '4px';
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
    video.onPlay.listen((_) => playBtn.text = '❚❚');
    video.onPause.listen((_) => playBtn.text = '►');

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
          flash(video.muted ? '🔇' : '🔊');
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
