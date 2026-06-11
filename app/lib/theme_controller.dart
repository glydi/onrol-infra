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

/// Selected profile-picture index (0 = letter avatar), persisted locally.
final ValueNotifier<int> avatarNotifier = ValueNotifier(0);
const _avatarKey = 'onrol_avatar';

Future<void> loadAvatar() async {
  try {
    final v = await _storage.read(key: _avatarKey);
    if (v != null) avatarNotifier.value = int.tryParse(v) ?? 0;
  } catch (_) {}
}

Future<void> setAvatar(int i) async {
  avatarNotifier.value = i;
  try {
    await _storage.write(key: _avatarKey, value: '$i');
  } catch (_) {}
}
