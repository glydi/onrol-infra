// Web video element with hls.js for HLS (.m3u8) streaming. mp4 plays via the
// native <video>; .m3u8 is streamed by hls.js (Chrome/Firefox) or natively
// (Safari). Download/right-click are disabled; the watermark sits on top.
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

// Each open registers a fresh view factory so [startAt]/callbacks are current
// (factories are cached by view type, so we use a unique type per open).
int _seq = 0;

Widget hlsVideoElement(
  String url, {
  double startAt = 0,
  void Function(double position, double duration)? onTime,
  void Function()? onEnded,
}) {
  final viewType = 'onrol-video-${_seq++}';
  ui_web.platformViewRegistry.registerViewFactory(viewType, (int id) {
    final video = html.VideoElement()
      ..controls = true
      ..autoplay = true
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.backgroundColor = 'black'
      ..setAttribute('controlsList', 'nodownload noplaybackrate noremoteplayback')
      ..setAttribute('playsinline', 'true')
      ..setAttribute('disablePictureInPicture', 'true');

    // Resume: seek to the saved position once metadata is available.
    if (startAt > 0) {
      video.onLoadedMetadata.listen((_) {
        try {
          video.currentTime = startAt;
        } catch (_) {}
      });
    }
    // Report playback position (for "resume where you stopped").
    if (onTime != null) {
      video.onTimeUpdate.listen((_) {
        final d = video.duration;
        final dur = (d.isFinite && !d.isNaN) ? d.toDouble() : 0.0;
        onTime(video.currentTime.toDouble(), dur);
      });
    }
    if (onEnded != null) {
      video.onEnded.listen((_) => onEnded());
    }

    final isHls = url.toLowerCase().contains('.m3u8');
    final hlsAvailable = js.context.hasProperty('Hls');
    if (isHls && hlsAvailable && (js.context['Hls'].callMethod('isSupported') as bool? ?? false)) {
      // Stream HLS via hls.js (Chrome/Firefox).
      final hls = js.JsObject(js.context['Hls'] as js.JsFunction);
      hls.callMethod('loadSource', [url]);
      hls.callMethod('attachMedia', [video]);
    } else {
      // mp4, or HLS on Safari (native support).
      video.src = url;
    }
    return video;
  });
  return HtmlElementView(viewType: viewType);
}
