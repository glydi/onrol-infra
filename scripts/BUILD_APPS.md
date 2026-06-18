# Building the ONROL Learn apps

One Flutter codebase (`app/`) builds **Web, Android, iOS, and Windows**. These
scripts wrap the right `flutter build` commands so you can clone the repo and go.

By default the apps talk to the live API `https://lms.187-127-178-100.sslip.io`.

## What can be built where

| Target  | Build on            | Script |
|---------|---------------------|--------|
| Web     | Windows / Mac / Linux | `build_web.bat`  / `build_apps.sh web` |
| Android | Windows / Mac / Linux | `build_android.bat` / `build_apps.sh android` |
| Windows | **Windows only**      | `build_windows.bat` |
| iOS     | **macOS only**        | `build_apps.sh ios` |

(You can't cross-build: no Windows `.exe` on a Mac, no iOS on Windows.)

## On Windows (clone, then run)

Prerequisites:
- **Flutter** (stable): https://docs.flutter.dev/get-started/install/windows
- For Windows builds: **Visual Studio 2022** + "Desktop development with C++"
- For Android builds: **Android Studio** (SDK), then `flutter doctor --android-licenses`
- Verify with `flutter doctor`

Then, from the repo root:
```bat
scripts\build_all.bat        :: web + android + windows
scripts\build_windows.bat    :: just the Windows student app
scripts\build_android.bat    :: just the APK
scripts\build_web.bat        :: just the web bundle
```

Outputs:
- Web     → `app\build\web\`
- Android → `app\build\app\outputs\flutter-apk\app-release.apk`
- Windows → `app\build\windows\x64\runner\Release\`  (the whole folder is the app)

## On macOS / Linux

```bash
scripts/build_apps.sh          # web + android (+ iOS on macOS)
scripts/build_apps.sh web      # one target: web | android | ios
```

## Notes
- The **Windows** build is the **student-only** app (`--dart-define=STUDENT_APP=true`)
  — no staff console/CRM, recording blocked (black in any screen capture).
- `--no-tree-shake-icons` is required everywhere — the UI picks icons at runtime.
- **Windows/desktop video** currently needs the `media_kit` player (the mobile
  `video_player` has no Windows support). If video must work on the Windows build,
  ask to have `media_kit` wired in first.
- The backend/API + web deploy to the VPS use `scripts/deploy.sh` (separate from
  these client-app builds).
