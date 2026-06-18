// Web video element with hls.js for HLS (.m3u8) streaming. mp4 plays via the
// native <video>; .m3u8 is streamed by hls.js (Chrome/Firefox) or natively
// (Safari). The native browser controls are removed — playback is driven by
// Netflix-style keyboard shortcuts + click, with an on-video feedback badge and
// a slim progress bar. Download/right-click are disabled; the watermark sits on
// top.
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

    // Wrapper so the feedback badge + progress bar can overlay the video and
    // the whole player can go fullscreen as one unit.
    final container = html.DivElement()
      ..style.position = 'relative'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.background = 'black'
      ..style.overflow = 'hidden'
      ..style.outline = 'none'
      ..tabIndex = 0; // focusable so it can take key events when clicked

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
      ..style.letterSpacing = '0.5px'
      ..style.pointerEvents = 'none'
      ..style.opacity = '0'
      ..style.transition = 'opacity 0.22s ease'
      ..style.zIndex = '6';

    // Slim bottom progress bar.
    final barTrack = html.DivElement()
      ..style.position = 'absolute'
      ..style.left = '0'
      ..style.right = '0'
      ..style.bottom = '0'
      ..style.height = '4px'
      ..style.background = 'rgba(255,255,255,0.18)'
      ..style.pointerEvents = 'none'
      ..style.zIndex = '5';
    final barFill = html.DivElement()
      ..style.height = '100%'
      ..style.width = '0%'
      ..style.background = '#FF4F2B';
    barTrack.append(barFill);

    container.append(video);
    container.append(barTrack);
    container.append(badge);

    // Deter right-click "Save video as…". (Not real protection — browsers can't
    // block screen recording; that needs DRM. The watermark is the deterrent.)
    video.onContextMenu.listen((e) => e.preventDefault());

    // ---- Feedback badge -----------------------------------------------------
    Timer? badgeTimer;
    void flash(String text) {
      badge.text = text;
      badge.style.opacity = '1';
      badgeTimer?.cancel();
      badgeTimer = Timer(const Duration(milliseconds: 560), () => badge.style.opacity = '0');
    }

    double clamp(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

    // ---- Transport helpers --------------------------------------------------
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
      final d = video.duration;
      final dur = (d.isFinite && !d.isNaN) ? d.toDouble() : double.infinity;
      video.currentTime = clamp(video.currentTime.toDouble() + seconds, 0, dur);
      flash(seconds > 0 ? '⏩ ${seconds}s' : '⏪ ${seconds.abs()}s');
    }

    void changeVolume(double delta) {
      video.muted = false;
      final v = clamp(video.volume.toDouble() + delta, 0, 1);
      video.volume = v;
      flash('🔊 ${(v * 100).round()}%');
    }

    void toggleMute() {
      video.muted = !video.muted;
      flash(video.muted ? '🔇' : '🔊');
    }

    void toggleFullscreen() {
      if (html.document.fullscreenElement != null) {
        html.document.exitFullscreen();
      } else {
        container.requestFullscreen();
      }
    }

    void jumpToFraction(double f) {
      final d = video.duration;
      if (d.isFinite && !d.isNaN) {
        video.currentTime = d * clamp(f, 0, 1);
        flash('${(f * 100).round()}%');
      }
    }

    // ---- Mouse: click = play/pause, double-click = fullscreen ---------------
    var lastClick = 0;
    video.onClick.listen((_) {
      // Defer slightly so a double-click (fullscreen) doesn't also toggle play.
      final now = DateTime.now().millisecondsSinceEpoch;
      final wasQuick = now - lastClick < 280;
      lastClick = now;
      if (wasQuick) return;
      Timer(const Duration(milliseconds: 240), () {
        if (DateTime.now().millisecondsSinceEpoch - lastClick >= 240) togglePlay();
      });
    });
    video.onDoubleClick.listen((e) {
      e.preventDefault();
      toggleFullscreen();
    });

    // ---- Keyboard (Netflix-style) -------------------------------------------
    _keySub?.cancel();
    _keySub = html.document.onKeyDown.listen((e) {
      // Ignore when this player isn't on screen, or when typing in a field.
      if (container.isConnected != true) return;
      final target = e.target;
      if (target is html.InputElement || target is html.TextAreaElement) return;

      final k = e.key;
      if (k == null) return;
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
          toggleMute();
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
    if (startAt > 0) {
      video.onLoadedMetadata.listen((_) {
        try {
          video.currentTime = startAt;
        } catch (_) {}
      });
    }
    // Report playback position (for "resume where you stopped") + drive the bar.
    video.onTimeUpdate.listen((_) {
      final d = video.duration;
      final dur = (d.isFinite && !d.isNaN) ? d.toDouble() : 0.0;
      final pos = video.currentTime.toDouble();
      if (dur > 0) barFill.style.width = '${(math.min(pos / dur, 1.0) * 100).toStringAsFixed(2)}%';
      onTime?.call(pos, dur);
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
