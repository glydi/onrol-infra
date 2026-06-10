import 'package:flutter/foundation.dart' show kIsWeb;

/// App-wide configuration.
class Config {
  /// Optional explicit override (mobile builds pass this):
  ///   flutter build apk --dart-define=ONROL_API_BASE=https://your.host
  static const String _override =
      String.fromEnvironment('ONROL_API_BASE', defaultValue: '');

  /// API base URL.
  /// - Web: default to the SAME origin the app is served from, so the browser
  ///   makes same-origin `/api` calls (nginx proxies them) — no CORS.
  /// - Mobile: use the override, or the LMS host as a sensible default.
  static String get apiBase {
    if (_override.isNotEmpty) return _override;
    if (kIsWeb) {
      final origin = Uri.base.origin;
      if (origin.isNotEmpty && origin.startsWith('http')) return origin;
    }
    return 'https://lms.187-127-178-100.sslip.io';
  }
}
