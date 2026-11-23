@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-RuTrackerConnection.ps1" -FindLocalProxy -Interactive
pause
