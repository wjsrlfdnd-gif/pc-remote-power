<#
.SYNOPSIS
    Discord 원격 전원 봇을 Windows 시작 시 자동 실행 작업(SYSTEM 권한)으로 등록하고 즉시 시작합니다.
    로그인 화면 상태에서도 부팅 완료 알림과 원격 종료/절전 명령이 동작하도록 구성합니다.
#>
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

$taskName = "PCRemotePowerBot"
$projectRoot = Split-Path -Parent $PSScriptRoot
$appDir = Join-Path $projectRoot "app"
$exePath = Join-Path $appDir "RemotePowerBot.exe"
$configPath = Join-Path $projectRoot "config.json"
$logPath = Join-Path $projectRoot "logs\bot.log"
$setupLogPath = Join-Path $projectRoot "logs\task-setup.log"

if (-not $isAdmin) {
    Write-Host "작업 스케줄러 등록을 위해 관리자 권한 UAC 승격 창을 띄웁니다..."
    try {
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs -Wait -PassThru
        if (Test-Path $setupLogPath) {
            Write-Host ""
            Get-Content -Path $setupLogPath -Encoding UTF8 | Select-Object -Last 25 | ForEach-Object { Write-Host $_ }
        }
        exit $proc.ExitCode
    }
    catch {
        Write-Host "[오류] 관리자 권한 승격이 취소되었거나 실패했습니다: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

$logDir = Split-Path -Parent $setupLogPath
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
Start-Transcript -Path $setupLogPath -Force | Out-Null
try {

if (-not (Test-Path $exePath)) {
    Write-Host "[오류] 실행 파일이 없습니다: $exePath" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $configPath)) {
    Write-Host "[오류] config.json 파일이 없습니다. 먼저 '2_디스코드_봇_설정.bat'을 실행해 주세요." -ForegroundColor Red
    exit 1
}

& $exePath --test-config
if ($LASTEXITCODE -ne 0) {
    Write-Host "[오류] config.json 검증에 실패했습니다. 먼저 '2_디스코드_봇_설정.bat'을 완료해 주세요." -ForegroundColor Red
    exit 1
}

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -ne $existing) {
    Write-Host "기존 작업 '$taskName' 중지 및 교체 중..."
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

$action = New-ScheduledTaskAction -Execute $exePath -WorkingDirectory $appDir
$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = 'PT15S'

$principal = New-ScheduledTaskPrincipal `
    -UserId "NT AUTHORITY\SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "PC 부팅 직후 실행되어 Discord로 부팅 알림 및 원격 종료/절전 제어를 제공합니다." | Out-Null

Write-Host "[등록 완료] 작업 스케줄러 '$taskName' 등록 성공" -ForegroundColor Green

Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 4

$taskInfo = Get-ScheduledTask -TaskName $taskName
Write-Host "현재 작업 상태: $($taskInfo.State)" -ForegroundColor Cyan

if (Test-Path $logPath) {
    Write-Host ""
    Write-Host "=== 최근 봇 로그 (logs\bot.log) ===" -ForegroundColor Cyan
    Get-Content -Path $logPath -Tail 10 -Encoding UTF8
}
} finally {
    Stop-Transcript | Out-Null
}
