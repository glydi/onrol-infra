// Web video element with hls.js for HLS (.m3u8) streaming. mp4 plays via the
// native <video>; .m3u8 is streamed by hls.js (Chrome/Firefox) or natively
// (Safari). Download/right-click are disabled; the watermark sits on top.
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

final Set<String> _registered = {};

Widget hlsVideoElement(String url) {
  final viewType = 'onrol-video-${url.hashCode}';
  if (_registered.add(viewType)) {
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
      // Deter right-click "Save video as…". (Not real protection — browsers can't
      // block screen recording; that needs DRM. The watermark is the deterrent.)
      video.onContextMenu.listen((e) => e.preventDefault());

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
  }
  return HtmlElementView(viewType: viewType);
}
