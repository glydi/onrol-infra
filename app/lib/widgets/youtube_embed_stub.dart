import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// One controller per embed so the (our-side) unmute button can drive the player.
final _ytControllers = <String, InAppWebViewController>{};

String _embedUrl(String id) =>
    'https://www.youtube-nocookie.com/embed/$id'
    '?autoplay=1&mute=1&controls=0&rel=0&modestbranding=1'
    '&playsinline=1&iv_load_policy=3&fs=0&disablekb=1&enablejsapi=1';

/// Clean YouTube-Live embed as the VIDEO source in our live room on mobile:
/// loaded in a WebView with controls off and muted autoplay (allowed without a
/// gesture via mediaPlaybackRequiresUserGesture=false). Sound is turned on by
/// our own button via [youtubeUnmute].
Widget youtubeEmbed(String videoId) => InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(_embedUrl(videoId))),
      initialSettings: InAppWebViewSettings(
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        javaScriptEnabled: true,
        transparentBackground: true,
      ),
      onWebViewCreated: (c) => _ytControllers[videoId] = c,
    );

/// Unmute + play the embedded video. The WebView page IS the YouTube player, so
/// we can reach its <video> element directly.
void youtubeUnmute(String videoId) {
  _ytControllers[videoId]?.evaluateJavascript(
      source: 'var v=document.querySelector("video"); if(v){v.muted=false; v.play();}');
}
