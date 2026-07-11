import 'dart:async';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

/// Embeds a provider (e.g. Zoho) live URL as an <iframe> — the VIDEO source
/// inside our own live room on web.
///
/// Cross-origin means we can neither click Zoho's controls for the student nor
/// hide them via CSS. So the frame starts interactive (they can press Zoho's
/// "Join now"); the moment focus enters the frame — i.e. they clicked into it —
/// we lock out further pointer input, so the hover control-bar stops appearing.
/// Video only from then on.
Widget liveEmbed(String url) {
  final viewType = 'live-embed-${url.hashCode}';
  // registerViewFactory throws if the same viewType is registered twice; a
  // stable id per URL plus swallowing the re-register error keeps it idempotent.
  try {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int id) {
      final iframe = html.IFrameElement()
        ..src = url
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%'
        ..allow = 'camera; microphone; autoplay; fullscreen; display-capture'
        ..allowFullscreen = true;
      // Lock pointer input the first time focus moves INTO this frame (the Join
      // click), so Zoho's hover controls stop showing. A tab-switch also blurs
      // the window, so we require the iframe to be the active element.
      StreamSubscription<html.Event>? sub;
      sub = html.window.onBlur.listen((_) {
        if (html.document.activeElement == iframe) {
          Future.delayed(const Duration(milliseconds: 500), () {
            iframe.style.pointerEvents = 'none';
          });
          sub?.cancel();
        }
      });
      return iframe;
    });
  } catch (_) {}
  return HtmlElementView(viewType: viewType);
}
