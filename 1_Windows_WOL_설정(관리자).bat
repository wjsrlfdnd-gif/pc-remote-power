@echo off
set "ROOT=%~dp0"
if not exist "%ROOT%scripts\1-configure-windows-wol.ps1" goto :missing
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\1-configure-windows-wol.ps1" -LogFile "%ROOT%logs\wol-setup.log"
pause
exit /b %errorlevel%

:missing
echo [ERROR] Please run this file inside the cloned/downloaded repository folder.
pause
exit /b 1
