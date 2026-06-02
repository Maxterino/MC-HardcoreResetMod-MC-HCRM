@echo off
cd /d "%~dp0"
echo ===============================================================
echo   MCHC Hardcore - SETUP
echo   Dit downloadt de server en alle mods en bouwt de mod-jar.
echo   Zorg dat je internet hebt en Java 25 is geinstalleerd.
echo ===============================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
echo.
pause
