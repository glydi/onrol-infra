import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// Owns the per-install device identity sent as X-Device-UUID.
///
/// NOTE: this id is client-generated and therefore SPOOFABLE — the backend
/// treats it as untrusted and gates the real security on attestation
/// (ATTESTATION_MODE). See ARCHITECTURE.md §2.1. We persist it in the platform
/// secure store so it survives app restarts but resets on reinstall.
class DeviceService {
  static const _storage = FlutterSecureStorage();
  static const _key = 'onrol_device_uuid';

  String? _cached;
  String platform = 'unknown';
  String model = 'unknown';

  Future<String> deviceId() async {
    if (_cached != null) return _cached!;
    var id = await _storage.read(key: _key);
    if (id == null) {
      id = const Uuid().v4();
      await _storage.write(key: _key, value: id);
    }
    _cached = id;
    return id;
  }

  Future<void> loadDeviceInfo() async {
    final info = DeviceInfoPlugin();
    try {
      // Lazy platform detection without dart:io import churn.
      final android = await info.androidInfo;
      platform = 'android';
      model = '${android.manufacturer} ${android.model}';
    } catch (_) {
      try {
        final ios = await info.iosInfo;
        platform = 'ios';
        model = ios.utsname.machine;
      } catch (_) {/* desktop/web during dev */}
    }
  }
}
