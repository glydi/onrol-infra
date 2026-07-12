import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

// The exact same-origin technique — reach into the iframe and press Zoho's Join
// button. Runs on the page as plain JS. It ONLY works if the iframe is
// same-origin; Zoho serves meeting.zoho.in, a different origin, so
// `f.contentWindow.document` throws a cross-origin SecurityError and each attempt
// silently no-ops. Kept so the behaviour is verifiable in the browser.
const _pressJs = r'''
(function(){
  var tries = 0;
  var t = setInterval(function(){
    tries++;
    try {
      var frames = document.querySelectorAll('iframe');
      for (var i = 0; i < frames.length; i++) {
        var f = frames[i];
        try {
          var doc = f.contentWindow.document;              // same-origin only; cross-origin THROWS here
          var btn = doc.getElementById('joinWebinarBtn');
          if (btn) { btn.click(); }
          if (f.contentWindow.myWindow) { f.contentWindow.myWindow.joinTheWebinar(); }
        } catch (e) { /* cross-origin frame — browser blocked access */ }
      }
    } catch (e) {}
    if (tries > 40) { clearInterval(t); }
  }, 800);
})();
''';

var _pressInjected = false;

/// Embeds a provider (e.g. Zoho) live URL as an <iframe> — the VIDEO source
/// inside our own live room on web. Opaque strips cover Zoho's top/bottom control
/// bars (we can't hide them inside a cross-origin frame, but we can cover them
/// from our side), while the centre — the video and "Join Now" — stays visible
/// and tappable so the student can still join (we can't click it for them).
Widget liveEmbed(String url) {
  final viewType = 'live-embed-${url.hashCode}';
  try {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int id) {
      final container = html.DivElement()
        ..style.position = 'relative'
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.background = '#000'
        ..style.overflow = 'hidden';

      final f = html.IFrameElement()
        ..src = url
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%'
        ..allow = 'camera; microphone; autoplay; fullscreen; display-capture'
        ..allowFullscreen = true;

      // Top 30%: a transparent shield that intercepts all touch/hover (default
      // pointer-events) so Zoho's top controls can't be reached or triggered —
      // the video still shows through it.
      final top = html.DivElement()
        ..style.position = 'absolute'
        ..style.top = '0'
        ..style.left = '0'
        ..style.right = '0'
        ..style.height = '30%'
        ..style.background = 'transparent';
      // Bottom 10%: opaque cover over Zoho's bottom edge / control bar.
      final bottom = html.DivElement()
        ..style.position = 'absolute'
        ..style.bottom = '0'
        ..style.left = '0'
        ..style.right = '0'
        ..style.height = '10%'
        ..style.background = '#000';

      container.append(f);
      container.append(top);
      container.append(bottom);
      return container;
    });
  } catch (_) {}
  // Inject the same-origin press attempt once for the page.
  if (!_pressInjected) {
    _pressInjected = true;
    html.document.head?.append(html.ScriptElement()..text = _pressJs);
  }
  return HtmlElementView(viewType: viewType);
}
