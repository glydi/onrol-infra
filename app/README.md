# ONROL Learn — Flutter client

Student app for the ONROL backend (login + device binding, live class via Zoho
embed with identity watermark, encrypted VOD). Talks to the deployed API at
`https://187-127-178-100.sslip.io` by default.

> Scaffolded without a Flutter SDK in the build environment, so it has **not been
> compiled here**. The Dart is written to current Flutter 3.22 / Dart 3.4 APIs.
> Generate the platform folders and run as below.

## Run

```bash
cd app
flutter create --org in.onrol --project-name onrol_app .   # generates android/ ios/
flutter pub get
flutter run --dart-define=ONROL_WEBINAR_ID=<a-webinar-uuid>
```

Create a webinar + a test student first (admin key is in the server's
`/opt/onrol/.env`):

```bash
H=https://187-127-178-100.sslip.io; AK=<ADMIN_API_KEY>
curl -s -X POST $H/api/v1/admin/webinars -H "X-Admin-Key: $AK" -H 'Content-Type: application/json' \
  -d '{"title":"Live Class","embed_session_id":"1362481714"}'   # -> webinar id
curl -s -X POST $H/api/v1/admin/users -H "X-Admin-Key: $AK" -H 'Content-Type: application/json' \
  -d '{"email":"you@example.com","full_name":"You","password":"hunter2pass","role":"student"}'
```

## What's implemented

| Feature | Status |
|---|---|
| Device id (`X-Device-UUID`) persisted in Keystore/Keychain | ✅ `services/device_service.dart` |
| Login + JWT stored securely + 2-device-limit UX | ✅ `services/auth_service.dart`, `screens/login_screen.dart` |
| Live class in embedded WebView (Zoho) | ✅ `screens/live_screen.dart` |
| Moving identity watermark over live video | ✅ `widgets/watermark_overlay.dart` |
| Screenshot/recording block (Android FLAG_SECURE) | ⚙️ apply snippet below after `flutter create` |
| iOS screen-capture detection | ⚙️ note below (needs Runner code) |
| Encrypted VOD playback | ⛔ backend key endpoint ready; see "VOD" below |

## Android: FLAG_SECURE (blocks screenshots + screen recording app-wide)

After `flutter create`, edit `android/app/src/main/kotlin/.../MainActivity.kt`:

```kotlin
package in.onrol.onrol_app

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
    }
}
```

(A copy lives at `android_MainActivity.kt.example` in this folder.)

## iOS: screen-capture detection

iOS can't blank the screen like FLAG_SECURE, but you can pause playback when a
recording starts. In `ios/Runner/AppDelegate.swift`, observe
`UIScreen.capturedDidChangeNotification` and check `UIScreen.main.isCaptured`,
then notify Flutter via a `MethodChannel` to pause the WebView/player.

## VOD (encrypted HLS) — the honest design note

The backend serves the AES-128 key at `GET /api/v1/hls/key/:video_id`, gated by
auth + device + enrollment. **Native players (video_player/ExoPlayer/AVPlayer)
can't attach our `Authorization` + `X-Device-UUID` headers to the key request**
that the `.m3u8` triggers. Two real options:

1. **Signed short-lived key URL** (recommended): add a backend route that mints a
   `…/hls/key/:id?t=<hmac>` URL the player can fetch header-free. Smallest change,
   works with any player.
2. **In-app local proxy**: run a loopback HTTP server in the app that injects the
   headers and rewrites the key URI. More moving parts.

Until one is wired, VOD playback is intentionally not faked in the UI. The live
path is fully functional today.
