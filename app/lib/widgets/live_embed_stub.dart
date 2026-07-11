import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// Video only: block USER pointer input so Zoho's hover/tap control bar never
// appears — our live room already supplies Q&A/chat/reactions. The video keeps
// auto-playing (mediaPlaybackRequiresUserGesture is false), so this doesn't stop
// playback. A scripted .click() (below) is NOT affected by pointer-events, so we
// can still auto-press "Join now" even though manual touch is disabled.
const _hideZohoControlsCss = '''
html, body { pointer-events: none !important; }
''';

// Auto-press Zoho's attendee "Join Now" so the student enters without a tap. The
// button is `#joinWebinarBtn` and its handler is `myWindow.joinTheWebinar()`, so
// we (1) call that handler directly — the most reliable trigger since the button
// uses a custom data-zm-click, not a native onclick — (2) click the button by id,
// and (3) fall back to matching the exact "Join Now" text. Scripted calls aren't
// blocked by pointer-events:none. Retries ~42s as the SPA mounts/rebuilds.
const _autoJoinJs = r'''
(function(){
  var tries = 0;
  var timer = setInterval(function(){
    tries++;
    try {
      if (window.myWindow && typeof window.myWindow.joinTheWebinar === 'function') {
        window.myWindow.joinTheWebinar();
      }
      var btn = document.getElementById('joinWebinarBtn');
      if (btn) { btn.click(); }
      var nodes = document.querySelectorAll('button, a, [role="button"]');
      for (var i = 0; i < nodes.length; i++) {
        var t = ((nodes[i].innerText || nodes[i].textContent || '') + '').trim().toLowerCase();
        if (t === 'join now' || t === 'join') { nodes[i].click(); }
      }
    } catch (e) {}
    if (tries > 60) clearInterval(timer);
  }, 700);
})();
''';

/// Embeds a provider (e.g. Zoho) live URL as an inline WebView — used as the
/// VIDEO source inside our own live room on mobile, so the surrounding UI (Q&A,
/// chat, watermark, header) stays the app's own. On web an <iframe> is used
/// instead (see live_embed_web.dart).
Widget liveEmbed(String url) => InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: InAppWebViewSettings(
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        javaScriptEnabled: true,
        // Keep popups (window.open / target=_blank — Zoho uses these to open the
        // actual meeting) inside this WebView instead of the system browser.
        javaScriptCanOpenWindowsAutomatically: true,
        supportMultipleWindows: true,
      ),
      onCreateWindow: (controller, req) async {
        final u = req.request.url;
        if (u != null) controller.loadUrl(urlRequest: URLRequest(url: u));
        return false;
      },
      shouldOverrideUrlLoading: (_, __) async => NavigationActionPolicy.ALLOW,
      // Once the page settles: hide controls (block pointer input) and auto-join.
      // CSS rules also apply to controls the SPA mounts later; the auto-join loop
      // keeps trying as the join button appears. Both re-run on every navigation.
      onLoadStop: (controller, _) async {
        await controller.injectCSSCode(source: _hideZohoControlsCss);
        await controller.evaluateJavascript(source: _autoJoinJs);
      },
    );
