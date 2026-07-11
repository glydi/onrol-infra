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
/// inside our own live room on web.
Widget liveEmbed(String url) {
  final viewType = 'live-embed-${url.hashCode}';
  try {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int id) {
      return html.IFrameElement()
        ..src = url
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%'
        ..allow = 'camera; microphone; autoplay; fullscreen; display-capture'
        ..allowFullscreen = true;
    });
  } catch (_) {}
  // Inject the same-origin press attempt once for the page.
  if (!_pressInjected) {
    _pressInjected = true;
    html.document.head?.append(html.ScriptElement()..text = _pressJs);
  }
  return HtmlElementView(viewType: viewType);
}
