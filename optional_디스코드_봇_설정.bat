@echo off
set "ROOT=%~dp0"
if not exist "%ROOT%scripts\2-setup-discord-bot.ps1" goto :missing
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\2-setup-discord-bot.ps1"
if %errorlevel% equ 0 echo Next: run scripts\3-register-autostart-task.ps1 as Administrator.
pause
exit /b %errorlevel%

:missing
echo [ERROR] Please run this file inside the cloned/downloaded repository folder.
pause
exit /b 1
