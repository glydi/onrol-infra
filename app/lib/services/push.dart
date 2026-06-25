import 'api_client.dart';
import 'auth_service.dart';
import 'web_push_stub.dart' if (dart.library.html) 'web_push_web.dart';

/// Web Push helper: one place that wires the browser subscription to our API.
class Push {
  /// Subscribe this browser to push. [prompt] asks for notification permission
  /// if needed (call from a user gesture). Returns true if subscribed; a no-op
  /// returning false on mobile/desktop (web-only feature).
  static Future<bool> enable(AuthService auth, {required bool prompt}) {
    return initWebPush(
      prompt: prompt,
      getVapidKey: () async {
        try {
          final r = await auth.apiGet('/api/v1/push/public-key');
          final d = ApiClient.decode(r);
          return d['enabled'] == true ? d['public_key']?.toString() : null;
        } catch (_) {
          return null;
        }
      },
      saveSubscription: (sub) async {
        try {
          await auth.apiPost('/api/v1/me/push/subscribe', sub);
        } catch (_) {}
      },
    );
  }
}
