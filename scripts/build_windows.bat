@echo off
REM Build the ONROL Learn STUDENT app for Windows (.exe).
REM Requires: Flutter (stable) + Visual Studio 2022 with "Desktop development with C++".
setlocal
where flutter >nul 2>nul || (echo [ERROR] Flutter is not in PATH. Install: https://docs.flutter.dev/get-started/install/windows & exit /b 1)
cd /d "%~dp0..\app" || exit /b 1

echo === Building ONROL Learn (Windows, student-only) ===
call flutter config --enable-windows-desktop
call flutter pub get                                          || (echo [ERROR] pub get failed & exit /b 1)
call flutter build windows --release --no-tree-shake-icons --dart-define=STUDENT_APP=true
if errorlevel 1 (echo [ERROR] Windows build failed & exit /b 1)

echo.
echo === DONE ===
echo App folder: app\build\windows\x64\runner\Release\
echo Zip that whole Release folder to share it, or run onrol_app.exe inside it.
endlocal
