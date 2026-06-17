import 'dart:convert';
import 'package:http/http.dart' as http;

import '../config.dart';
import 'device_service.dart';

/// Thin HTTP client that injects X-Device-UUID on every request and the bearer
/// token when present — mirroring the backend's auth + device-binding contract.
class ApiClient {
  ApiClient(this._device);

  final DeviceService _device;
  String? _token;

  set token(String? t) => _token = t;
  bool get isAuthed => _token != null;

  Future<Map<String, String>> _headers({bool json = true}) async {
    final h = <String, String>{
      'X-Device-UUID': await _device.deviceId(),
    };
    if (json) h['Content-Type'] = 'application/json';
    if (_token != null) h['Authorization'] = 'Bearer $_token';
    return h;
  }

  Uri _u(String path) => Uri.parse('${Config.apiBase}$path');

  Future<http.Response> postJson(String path, Map<String, dynamic> body) async {
    return http.post(_u(path), headers: await _headers(), body: jsonEncode(body));
  }

  Future<http.Response> patchJson(String path, Map<String, dynamic> body) async {
    return http.patch(_u(path), headers: await _headers(), body: jsonEncode(body));
  }

  Future<http.Response> putJson(String path, Map<String, dynamic> body) async {
    return http.put(_u(path), headers: await _headers(), body: jsonEncode(body));
  }

  Future<http.Response> get(String path) async {
    return http.get(_u(path), headers: await _headers(json: false));
  }

  Future<http.Response> delete(String path) async {
    return http.delete(_u(path), headers: await _headers(json: false));
  }

  /// Decode a JSON object body, throwing a readable error on non-2xx.
  static Map<String, dynamic> decode(http.Response r) {
    final data = r.body.isNotEmpty
        ? jsonDecode(r.body) as Map<String, dynamic>
        : <String, dynamic>{};
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw ApiException(r.statusCode, data['error']?.toString() ?? 'request failed', data);
    }
    return data;
  }
}

class ApiException implements Exception {
  ApiException(this.status, this.message, [this.data]);
  final int status;
  final String message;
  final Map<String, dynamic>? data;
  @override
  String toString() => 'ApiException($status): $message';
}
