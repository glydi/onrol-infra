// Mobile/desktop no-op. Web Push is a browser-only feature; native push (FCM)
// would be wired separately. Web uses web_push_web.dart.
Future<bool> initWebPush({
  required bool prompt,
  required Future<String?> Function() getVapidKey,
  required Future<void> Function(Map<String, dynamic> sub) saveSubscription,
}) async =>
    false;
