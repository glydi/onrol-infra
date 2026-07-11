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

// Auto-press Zoho's "Join Now"/entry (and any "join audio") button as the SPA
// mounts it, so the student enters the session without a tap. A scripted click
// isn't blocked by pointer-events:none. We scan ALL elements (Zoho renders the
// button as a styled div/span, not always a <button>), match the exact join
// text, and click the clickable ancestor. Retries ~48s as the page rebuilds.
const _autoJoinJs = r'''
(function(){
  var tries = 0;
  function label(el){ return ((el.innerText || el.textContent || el.value || (el.getAttribute && el.getAttribute('aria-label')) || '') + '').trim().toLowerCase(); }
  function visible(el){ var r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; }
  var timer = setInterval(function(){
    tries++;
    try {
      var nodes = document.querySelectorAll('button, a, [role="button"], input[type="button"], input[type="submit"], div, span');
      for (var i = 0; i < nodes.length; i++) {
        var el = nodes[i], t = label(el);
        if (/^join now$|^join$|^join webinar$|^join the webinar$|^join meeting$|^join with computer audio$|^join audio$/.test(t) && visible(el)) {
          (el.closest('button, a, [role="button"], input') || el).click();
        }
      }
    } catch (e) {}
    if (tries > 60) clearInterval(timer);
  }, 800);
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
