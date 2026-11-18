@echo off
chcp 65001 > nul
set "ROOT=%~dp0"
if not exist "%ROOT%scripts\install-and-build.ps1" (
  echo [오류] 저장소 전체 폴더를 다운로드하거나 git clone한 위치 안에서 실행해 주세요.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\install-and-build.ps1"
pause
