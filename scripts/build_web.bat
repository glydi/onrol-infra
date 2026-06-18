@echo off
REM Build the ONROL Learn web app (static files for nginx). Requires Flutter.
setlocal
where flutter >nul 2>nul || (echo [ERROR] Flutter is not in PATH. & exit /b 1)
cd /d "%~dp0..\app" || exit /b 1

echo === Building ONROL Learn (Web) ===
call flutter pub get                                          || (echo [ERROR] pub get failed & exit /b 1)
call flutter build web --no-tree-shake-icons --pwa-strategy=none
if errorlevel 1 (echo [ERROR] Web build failed & exit /b 1)

echo.
echo === DONE ===
echo Web files: app\build\web\   (deploy these to the web server)
endlocal
