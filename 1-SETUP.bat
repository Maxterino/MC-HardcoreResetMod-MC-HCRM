@echo off
cd /d "%~dp0"
echo ===============================================================
echo   MCHC Hardcore - SETUP
echo   This downloads the server and all mods and builds the mod jar.
echo   Make sure you have internet and Java 25 installed.
echo ===============================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
echo.
pause
