import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// App-wide theme mode (Light / Dark / System), persisted across launches.
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.system);

const _storage = FlutterSecureStorage();
const _key = 'onrol_theme';

Future<void> loadTheme() async {
  try {
    final v = await _storage.read(key: _key);
    themeNotifier.value = switch (v) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  } catch (_) {}
}

Future<void> setTheme(ThemeMode m) async {
  themeNotifier.value = m;
  final s = switch (m) {
    ThemeMode.light => 'light',
    ThemeMode.dark => 'dark',
    ThemeMode.system => 'system',
  };
  try {
    await _storage.write(key: _key, value: s);
  } catch (_) {}
}

/// App-wide text scale (font size). 0.9 = small, 1.0 = default, 1.15 = large.
final ValueNotifier<double> textScaleNotifier = ValueNotifier(1.0);
const _scaleKey = 'onrol_text_scale';

Future<void> loadTextScale() async {
  try {
    final d = double.tryParse(await _storage.read(key: _scaleKey) ?? '');
    if (d != null && d >= 0.8 && d <= 1.4) textScaleNotifier.value = d;
  } catch (_) {}
}

Future<void> setTextScale(double v) async {
  textScaleNotifier.value = v;
  try {
    await _storage.write(key: _scaleKey, value: v.toString());
  } catch (_) {}
}

/// App accent colour preference (Theme color). Defaults to the ONROL red-orange.
final ValueNotifier<Color> accentNotifier = ValueNotifier(const Color(0xFFFF4F2B));
const _accentKey = 'onrol_accent';

Future<void> loadAccent() async {
  try {
    final n = int.tryParse(await _storage.read(key: _accentKey) ?? '');
    if (n != null) accentNotifier.value = Color(n);
  } catch (_) {}
}

Future<void> setAccent(Color c) async {
  accentNotifier.value = c;
  try {
    await _storage.write(key: _accentKey, value: c.value.toString());
  } catch (_) {}
}

/// The user's profile picture: a preset id ("p:3") or a data URI for an
/// uploaded photo; '' = the default letter avatar. The source of truth is the
/// backend (users.avatar); this is also cached locally for instant first paint.
final ValueNotifier<String> avatarNotifier = ValueNotifier('');
const _avatarKey = 'onrol_avatar';

Future<void> loadAvatar() async {
  try {
    avatarNotifier.value = await _storage.read(key: _avatarKey) ?? '';
  } catch (_) {}
}

/// Updates the local cache + notifier (the API call is made by the caller, who
/// has the auth client).
Future<void> cacheAvatar(String v) async {
  avatarNotifier.value = v;
  try {
    await _storage.write(key: _avatarKey, value: v);
  } catch (_) {}
}
