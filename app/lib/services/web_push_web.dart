import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

/// Subscribes this browser to Web Push.
///
/// [prompt] = true asks for notification permission if it hasn't been granted
/// (call this from a user gesture, e.g. a settings toggle). [prompt] = false is
/// the silent path used on app load: it only (re)subscribes when permission was
/// already granted, never showing a prompt. Returns true once a subscription has
/// been registered + saved. Everything is wrapped so it can never crash the app.
Future<bool> initWebPush({
  required bool prompt,
  required Future<String?> Function() getVapidKey,
  required Future<void> Function(Map<String, dynamic> sub) saveSubscription,
}) async {
  try {
    final container = html.window.navigator.serviceWorker;
    if (container == null) return false; // unsupported browser

    final perm = html.Notification.permission;
    if (perm == 'denied') return false;
    if (perm != 'granted') {
      if (!prompt) return false; // don't nag on load
      final res = await html.Notification.requestPermission();
      if (res != 'granted') return false;
    }

    final vapid = await getVapidKey();
    if (vapid == null || vapid.isEmpty) return false;

    // Register our dedicated push worker (separate from Flutter's, which is off).
    await container.register('push-sw.js');
    final reg = await container.ready;

    final pm = reg.pushManager;
    if (pm == null) return false;

    // subscribe() returns the existing subscription if one already exists for
    // this applicationServerKey, otherwise creates a new one.
    final sub = await pm.subscribe(<String, dynamic>{
      'userVisibleOnly': true,
      'applicationServerKey': _urlBase64ToBytes(vapid),
    });

    final endpoint = sub.endpoint;
    final p256dh = _keyB64(sub.getKey('p256dh'));
    final auth = _keyB64(sub.getKey('auth'));
    if (endpoint == null || p256dh == null || auth == null) return false;

    await saveSubscription(<String, dynamic>{
      'endpoint': endpoint,
      'keys': <String, String>{'p256dh': p256dh, 'auth': auth},
    });
    return true;
  } catch (_) {
    return false; // best-effort
  }
}

// VAPID public keys are base64url (no padding); the Push API wants the raw bytes.
Uint8List _urlBase64ToBytes(String input) {
  var s = input.replaceAll('-', '+').replaceAll('_', '/');
  while (s.length % 4 != 0) {
    s += '=';
  }
  return base64Decode(s);
}

// Encode a subscription key (raw bytes) as unpadded base64url — the shape the
// server's webpush library expects.
String? _keyB64(ByteBuffer? buf) {
  if (buf == null) return null;
  return base64Url.encode(buf.asUint8List()).replaceAll('=', '');
}
