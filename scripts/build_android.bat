@echo off
REM Build the ONROL Learn Android app (.apk). Requires Flutter + Android SDK
REM (install Android Studio, accept SDK licenses: flutter doctor --android-licenses).
setlocal
where flutter >nul 2>nul || (echo [ERROR] Flutter is not in PATH. & exit /b 1)
cd /d "%~dp0..\app" || exit /b 1

echo === Building ONROL Learn (Android APK) ===
call flutter pub get                                          || (echo [ERROR] pub get failed & exit /b 1)
call flutter build apk --release --no-tree-shake-icons
if errorlevel 1 (echo [ERROR] Android build failed & exit /b 1)

echo.
echo === DONE ===
echo APK: app\build\app\outputs\flutter-apk\app-release.apk
endlocal
