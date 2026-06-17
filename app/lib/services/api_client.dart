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

  Future<http.Response> get(String path) async {
    // Cache-bust so the browser (web) never serves a stale API response, and ask
    // intermediaries not to cache — fixes "data not reloading" after changes.
    final sep = path.contains('?') ? '&' : '?';
    final busted = '$path${sep}_ts=${DateTime.now().millisecondsSinceEpoch}';
    final headers = await _headers(json: false)
      ..['Cache-Control'] = 'no-cache, no-store'
      ..['Pragma'] = 'no-cache';
    return http.get(_u(busted), headers: headers);
  }

  Future<http.Response> delete(String path) async {
    return http.delete(_u(path), headers: await _headers(json: false));
  }

  /// Multipart upload (e.g. a video file to the store). [fields] are extra form
  /// fields sent alongside the file under [field].
  Future<http.Response> uploadBytes(String path, {
    required List<int> bytes,
    required String filename,
    String field = 'file',
    Map<String, String>? fields,
  }) async {
    final req = http.MultipartRequest('POST', _u(path));
    req.headers.addAll(await _headers(json: false));
    if (fields != null) req.fields.addAll(fields);
    req.files.add(http.MultipartFile.fromBytes(field, bytes, filename: filename));
    final streamed = await req.send();
    return http.Response.fromStream(streamed);
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
