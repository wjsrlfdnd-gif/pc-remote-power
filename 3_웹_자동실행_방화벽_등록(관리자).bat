@echo off
set "ROOT=%~dp0"
if not exist "%ROOT%scripts\register-web-autostart.ps1" goto :missing
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\register-web-autostart.ps1"
pause
exit /b %errorlevel%

:missing
echo [ERROR] Please run this file inside the cloned/downloaded repository folder.
pause
exit /b 1
