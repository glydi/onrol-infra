import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'device_service.dart';

class AuthUser {
  AuthUser({required this.id, required this.email, required this.fullName, required this.role, this.batch, this.course = ''});
  final String id;
  final String email;
  final String fullName;
  final String role; // student | instructor | manager | superadmin
  final int? batch; // student's batch number (null = unassigned)
  final String course; // student's course display title
  factory AuthUser.fromJson(Map<String, dynamic> j) => AuthUser(
        id: j['id']?.toString() ?? '',
        email: j['email']?.toString() ?? '',
        fullName: j['full_name']?.toString() ?? '',
        role: j['role']?.toString() ?? 'student',
        batch: (j['batch'] is int) ? j['batch'] as int : int.tryParse('${j['batch'] ?? ''}'),
        course: j['course']?.toString() ?? '',
      );
  bool get isStaff => role == 'instructor' || role == 'manager' || role == 'superadmin';
  bool get isAdmin => role == 'manager' || role == 'superadmin';
}

/// Login / session. Persists the JWT in the platform secure store.
class AuthService {
  AuthService(this._api, this._device);

  final ApiClient _api;
  final DeviceService _device;
  static const _storage = FlutterSecureStorage();
  static const _tokenKey = 'onrol_jwt';
  static const _credEmailKey = 'onrol_cred_email';
  static const _credPassKey = 'onrol_cred_pass';

  AuthUser? user;

  /// Remember the last-used credentials (in the platform secure store) so the
  /// login screen can prefill them after logout. Survives logout by design.
  Future<void> saveCredentials(String email, String password) async {
    try {
      await _storage.write(key: _credEmailKey, value: email);
      await _storage.write(key: _credPassKey, value: password);
    } catch (_) {}
  }

  Future<(String, String)?> savedCredentials() async {
    try {
      final e = await _storage.read(key: _credEmailKey);
      final p = await _storage.read(key: _credPassKey);
      if (e != null && e.isNotEmpty && p != null && p.isNotEmpty) return (e, p);
    } catch (_) {}
    return null;
  }

  Future<void> clearCredentials() async {
    try {
      await _storage.delete(key: _credEmailKey);
      await _storage.delete(key: _credPassKey);
    } catch (_) {}
  }

  /// Restore a persisted session: load the saved JWT, then validate it by
  /// fetching the profile (which also populates `user` + role for routing).
  /// Returns false (and clears the token) if it's missing or expired.
  Future<bool> restore() async {
    final t = await _storage.read(key: _tokenKey);
    if (t == null) return false;
    _api.token = t;
    try {
      final r = await _api.get('/api/v1/me/profile');
      final data = ApiClient.decode(r); // throws on 401/expired
      user = AuthUser.fromJson(data);
      return true;
    } catch (_) {
      _api.token = null;
      await _storage.delete(key: _tokenKey);
      return false;
    }
  }

  Future<void> login(String email, String password, {String portal = '', String? totp}) async {
    await _device.loadDeviceInfo();
    final r = await _api.postJson('/api/v1/auth/login', {
      'email': email,
      'password': password,
      'platform': _device.platform,
      'model': _device.model,
      'portal': portal,
      if (totp != null && totp.isNotEmpty) 'totp': totp,
    });
    final data = ApiClient.decode(r); // throws ApiException(409) on device limit
    final token = data['access_token'] as String;
    _api.token = token;
    await _storage.write(key: _tokenKey, value: token);
    if (data['user'] is Map) {
      user = AuthUser.fromJson(data['user'] as Map<String, dynamic>);
    }
  }

  /// Re-fetch the profile (after an edit) so `user` reflects the latest name etc.
  Future<void> refreshProfile() async {
    try {
      final r = await _api.get('/api/v1/me/profile');
      user = AuthUser.fromJson(ApiClient.decode(r));
    } catch (_) {}
  }

  Future<void> logout() async {
    _api.token = null;
    user = null;
    await _storage.delete(key: _tokenKey);
  }

  /// Current JWT (for players that must authenticate HLS key requests). '' if none.
  String get token => _api.token ?? '';

  // Authed call passthroughs for screens.
  Future<http.Response> apiPost(String path, Map<String, dynamic> body) =>
      _api.postJson(path, body);
  Future<http.Response> apiGet(String path) => _api.get(path);
  Future<http.Response> apiPatch(String path, Map<String, dynamic> body) =>
      _api.patchJson(path, body);
  Future<http.Response> apiPut(String path, Map<String, dynamic> body) =>
      _api.putJson(path, body);
  Future<http.Response> apiDelete(String path) => _api.delete(path);
  Future<http.Response> apiUpload(String path, {required List<int> bytes, required String filename, Map<String, String>? fields}) =>
      _api.uploadBytes(path, bytes: bytes, filename: filename, fields: fields);
  Future<http.Response> apiPostBytes(String path, List<int> bytes) => _api.postBytes(path, bytes);
}
