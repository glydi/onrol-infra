import 'dart:async';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

// Keep a handle to each embed's iframe so the (our-side) unmute button can drive
// the YouTube player via its postMessage JS API.
final _ytFrames = <String, html.IFrameElement>{};

String _embedUrl(String id) => 'https://www.youtube-nocookie.com/embed/$id'
    '?autoplay=1&mute=1&controls=0&rel=0&modestbranding=1'
    '&playsinline=1&iv_load_policy=3&fs=0&disablekb=1&enablejsapi=1';

/// Clean YouTube-Live embed as the VIDEO source in our live room on web:
/// controls off (no YouTube logo/chrome), autoplaying, pointer-events off (no
/// hover chrome, no click-through). A black cover hides YouTube's initial
/// play/loading button and only fades away once the player reports it's actually
/// PLAYING — so the student never sees a button, just black → video. Sound is
/// turned on by our own button via [youtubeUnmute].
Widget youtubeEmbed(String videoId) {
  final viewType = 'yt-$videoId';
  try {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int id) {
      final container = html.DivElement()
        ..style.position = 'relative'
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.background = '#000'
        ..style.overflow = 'hidden';

      final f = html.IFrameElement()
        ..src = _embedUrl(videoId)
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.pointerEvents = 'none'
        ..allow = 'autoplay; encrypted-media; picture-in-picture';

      // Opaque cover over the player — no button, no logo — until it's playing.
      final cover = html.DivElement()
        ..style.position = 'absolute'
        ..style.top = '0'
        ..style.left = '0'
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.background = '#000'
        ..style.transition = 'opacity 0.45s ease'
        ..style.pointerEvents = 'none';

      container.append(f);
      container.append(cover);
      _ytFrames[videoId] = f;

      var revealed = false;
      void doReveal() {
        if (revealed) return;
        revealed = true;
        cover.style.opacity = '0';
        // Drop it from hit/paint once faded.
        Timer(const Duration(milliseconds: 500), () => cover.remove());
      }

      // Hold the black cover for at least ~1s so YouTube's initial play/loading
      // button is fully gone before we reveal, then fade in on PLAYING.
      var playing = false;
      var minHeld = false;
      void maybeReveal() {
        if (minHeld && playing) doReveal();
      }

      f.onLoad.listen((_) {
        f.contentWindow?.postMessage('{"event":"listening"}', '*');
      });
      late final StreamSubscription<html.MessageEvent> sub;
      sub = html.window.onMessage.listen((e) {
        final d = e.data;
        if (d is String &&
            d.contains('onStateChange') &&
            d.contains('"info":1')) {
          playing = true;
          maybeReveal();
          sub.cancel();
        }
      });
      Timer(const Duration(milliseconds: 1000), () {
        minHeld = true;
        maybeReveal();
      });
      // Fallback: never leave the cover up forever if events don't arrive.
      Timer(const Duration(seconds: 7), doReveal);

      return container;
    });
  } catch (_) {}
  return HtmlElementView(viewType: viewType);
}

/// Unmute + play, triggered by our own in-room button (a user gesture, so the
/// browser allows audio). Uses the YouTube iframe postMessage API.
void youtubeUnmute(String videoId) {
  final w = _ytFrames[videoId]?.contentWindow;
  w?.postMessage('{"event":"command","func":"unMute","args":""}', '*');
  w?.postMessage('{"event":"command","func":"playVideo","args":""}', '*');
}

/// Host-driven mute/unmute (mirrors the room's Mute control onto the player).
void youtubeSetMuted(String videoId, bool muted) {
  final w = _ytFrames[videoId]?.contentWindow;
  w?.postMessage(
      '{"event":"command","func":"${muted ? 'mute' : 'unMute'}","args":""}',
      '*');
}
