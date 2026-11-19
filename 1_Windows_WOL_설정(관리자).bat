@echo off
set "ROOT=%~dp0"
if not exist "%ROOT%scripts\1-configure-windows-wol.ps1" goto :missing
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\1-configure-windows-wol.ps1" -LogFile "%ROOT%logs\wol-setup.log"
pause
exit /b %errorlevel%

:missing
echo [ERROR] Script not found: "%ROOT%scripts\1-configure-windows-wol.ps1"
echo [INFO] Current folder: "%ROOT%"
echo [TIP] If you downloaded a ZIP from GitHub, extract ALL files first (do not run inside the ZIP),
echo       and keep this .bat file in the same folder as the "scripts" folder.
pause
exit /b 1
