import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

// Keep a handle to each embed's iframe so the (our-side) unmute button can drive
// the YouTube player via its postMessage JS API.
final _ytFrames = <String, html.IFrameElement>{};

String _embedUrl(String id) =>
    'https://www.youtube-nocookie.com/embed/$id'
    '?autoplay=1&mute=1&controls=0&rel=0&modestbranding=1'
    '&playsinline=1&iv_load_policy=3&fs=0&disablekb=1&enablejsapi=1';

/// Clean YouTube-Live embed as the VIDEO source in our live room on web:
/// controls off (no YouTube logo/chrome), autoplaying, and pointer-events off so
/// no hover chrome appears and the student can't click through to YouTube. Sound
/// is turned on by our own button via [youtubeUnmute] (postMessage JS API).
Widget youtubeEmbed(String videoId) {
  final viewType = 'yt-$videoId';
  try {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int id) {
      final f = html.IFrameElement()
        ..src = _embedUrl(videoId)
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.pointerEvents = 'none'
        ..allow = 'autoplay; encrypted-media; picture-in-picture';
      _ytFrames[videoId] = f;
      return f;
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
