@echo off
chcp 65001 > nul
set "ROOT=%~dp0"
if not exist "%ROOT%scripts\2-setup-discord-bot.ps1" (
  echo [오류] 저장소 전체 폴더 안에서 실행해 주세요.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\2-setup-discord-bot.ps1"
if %errorlevel% equ 0 (
  echo.
  echo 부팅 자동 실행을 등록하려면 scripts\3-register-autostart-task.ps1 을 실행하세요.
)
pause
