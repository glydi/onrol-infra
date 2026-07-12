import 'package:flutter/cupertino.dart' hide Text;
import 'package:flutter/material.dart' hide Text;
import 'package:onrol_app/widgets/upper_text.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:google_fonts/google_fonts.dart';

import '../widgets/watermark_overlay.dart';

/// Renders the Zoho live/registration URL in an embedded WebView with the
/// student's identity watermark on top. Screenshot/recording blocking is applied
/// app-wide via FLAG_SECURE in MainActivity (Android). iOS capture detection is
/// noted in app/README.md.
class LiveScreen extends StatefulWidget {
  const LiveScreen({super.key, required this.url, required this.watermark});
  final String url;
  final String watermark;

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> {
  // Zoho renders its attendee button after the page itself has loaded. Retry
  // while the SPA mounts so students enter the class without pressing it.
  static const _autoJoinJs = r'''
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
        var text = ((nodes[i].innerText || nodes[i].textContent || '') + '').trim().toLowerCase();
        if (text === 'join now' || text === 'join') { nodes[i].click(); }
      }
    } catch (e) {}
    if (tries > 60) clearInterval(timer);
  }, 700);
})();
''';

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? const Color(0xFF1C1C1E) : Colors.white;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: bg.withValues(alpha: 0.85),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(CupertinoIcons.chevron_left, size: 22),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text('Live Class',
            style:
                GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 17)),
      ),
      body: WatermarkOverlay(
        label: widget.watermark,
        child: InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri(widget.url)),
          initialSettings: InAppWebViewSettings(
            mediaPlaybackRequiresUserGesture: false,
            allowsInlineMediaPlayback: true,
            javaScriptEnabled: true,
            // Keep popups (window.open / target=_blank — Zoho uses these to open
            // the actual meeting) inside the app instead of the system browser.
            javaScriptCanOpenWindowsAutomatically: true,
            supportMultipleWindows: true,
          ),
          // A new-window request (popup) is loaded into THIS WebView so the
          // student never leaves the app.
          onCreateWindow: (controller, req) async {
            final u = req.request.url;
            if (u != null) controller.loadUrl(urlRequest: URLRequest(url: u));
            return false;
          },
          // Every navigation stays in the WebView — never hand off to a browser.
          shouldOverrideUrlLoading: (_, __) async =>
              NavigationActionPolicy.ALLOW,
          onLoadStop: (controller, _) async {
            await controller.evaluateJavascript(source: _autoJoinJs);
          },
        ),
      ),
    );
  }
}
