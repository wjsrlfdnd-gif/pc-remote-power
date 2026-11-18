@echo off
chcp 65001 > nul
set "ROOT=%~dp0"
if not exist "%ROOT%scripts\1-configure-windows-wol.ps1" (
  echo [오류] 저장소 전체 폴더 안에서 실행해 주세요.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\1-configure-windows-wol.ps1" -LogFile "%ROOT%logs\wol-setup.log"
pause
