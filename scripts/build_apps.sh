#!/usr/bin/env bash
# Build ONROL Learn app targets on macOS / Linux: web, Android, and (macOS only) iOS.
# Windows .exe must be built on Windows — see scripts/build_*.bat.
#
# Usage:
#   scripts/build_apps.sh            # web + android (+ ios on macOS)
#   scripts/build_apps.sh web        # just one: web | android | ios
set -euo pipefail

cd "$(dirname "$0")/../app"
command -v flutter >/dev/null || { echo "[ERROR] Flutter is not in PATH."; exit 1; }

build_web()     { echo "=== Web ===";     flutter build web --no-tree-shake-icons --pwa-strategy=none;
                  echo "-> app/build/web/"; }
build_android() { echo "=== Android ==="; flutter build apk --release --no-tree-shake-icons;
                  echo "-> app/build/app/outputs/flutter-apk/app-release.apk"; }
build_ios()     { echo "=== iOS (no codesign) ==="; flutter build ios --release --no-codesign --no-tree-shake-icons;
                  echo "-> app/build/ios/iphoneos/Runner.app  (open ios/Runner.xcworkspace in Xcode to sign + archive an .ipa)"; }

flutter pub get

target="${1:-all}"
case "$target" in
  web)     build_web ;;
  android) build_android ;;
  ios)     build_ios ;;
  all)
    build_web
    build_android
    if [[ "$(uname)" == "Darwin" ]]; then build_ios; else echo "(skipping iOS — macOS only)"; fi
    ;;
  *) echo "Unknown target: $target (use web | android | ios)"; exit 1 ;;
esac
echo "=== DONE ==="
