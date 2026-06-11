import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
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
  double _progress = 0;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? const Color(0xFF1C1C1E) : Colors.white;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: bg.withOpacity(0.85),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(CupertinoIcons.chevron_left, size: 22),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text('Live Class', style: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 17)),
        bottom: _progress < 1
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(value: _progress, minHeight: 2, color: const Color(0xFF007AFF)),
              )
            : null,
      ),
      body: WatermarkOverlay(
        label: widget.watermark,
        child: InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri(widget.url)),
          initialSettings: InAppWebViewSettings(
            mediaPlaybackRequiresUserGesture: false,
            allowsInlineMediaPlayback: true,
            javaScriptEnabled: true,
          ),
          onProgressChanged: (_, p) => setState(() => _progress = p / 100),
        ),
      ),
    );
  }
}
