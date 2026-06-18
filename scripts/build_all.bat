@echo off
REM Build EVERY app target that can be built on Windows: Web, Android, Windows.
REM (iOS can only be built on a Mac — see scripts\build_apps.sh.)
setlocal
echo ============================================================
echo  ONROL Learn - building all Windows-capable app targets
echo ============================================================

call "%~dp0build_web.bat"
if errorlevel 1 (echo [ERROR] stopping: web build failed & exit /b 1)

call "%~dp0build_android.bat"
if errorlevel 1 (echo [ERROR] stopping: android build failed & exit /b 1)

call "%~dp0build_windows.bat"
if errorlevel 1 (echo [ERROR] stopping: windows build failed & exit /b 1)

echo.
echo ============================================================
echo  ALL DONE
echo   Web      : app\build\web\
echo   Android  : app\build\app\outputs\flutter-apk\app-release.apk
echo   Windows  : app\build\windows\x64\runner\Release\
echo ============================================================
endlocal
