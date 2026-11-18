<#
.SYNOPSIS
    RemotePowerWeb용 Windows 방화벽 인바운드 규칙, 부팅 자동 실행(PCRemotePowerWeb),
    그리고 사용자 세션 Antigravity 실행 작업(LaunchAntigravityForUser)을 등록합니다.
#>
param(
    [string]$TargetUser = "",
    [string]$AntigravityExe = ""
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

$taskName = "PCRemotePowerWeb"
$agyTaskName = "LaunchAntigravityForUser"
$ruleName = "PCRemotePowerWeb"
$projectRoot = Split-Path -Parent $PSScriptRoot
$webDir = Join-Path $projectRoot "web-app"
$stagingDir = Join-Path $projectRoot "web-app-staging"
$exePath = Join-Path $webDir "RemotePowerWeb.exe"
$configPath = Join-Path $projectRoot "web-config.json"
$logPath = Join-Path $projectRoot "logs\web.log"
$setupLogPath = Join-Path $projectRoot "logs\web-task-setup.log"

if (-not $isAdmin) {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $localAgy = Join-Path $env:LOCALAPPDATA "Programs\antigravity\Antigravity.exe"
    Write-Host "방화벽 설정 및 자동 실행 등록을 위해 관리자 권한 UAC 창을 띄웁니다..."
    try {
        $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -TargetUser `"$currentUser`" -AntigravityExe `"$localAgy`""
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs -Wait -PassThru
        if (Test-Path $setupLogPath) {
            Write-Host ""
            Get-Content -Path $setupLogPath -Encoding UTF8 | Select-Object -Last 30 | ForEach-Object { Write-Host $_ }
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
    if (-not (Test-Path $configPath)) {
        Write-Host "[오류] web-config.json이 없습니다. 먼저 '2_폰_원클릭_웹_설정.bat'을 실행해 주세요." -ForegroundColor Red
        exit 1
    }

    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
    Get-Process -Name "RemotePowerWeb" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    if (Test-Path $stagingDir) {
        if (-not (Test-Path $webDir)) { New-Item -ItemType Directory -Path $webDir -Force | Out-Null }
        Copy-Item -Path (Join-Path $stagingDir "*") -Destination $webDir -Recurse -Force
        Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[업데이트 완료] web-app-staging의 최신 빌드를 web-app에 반영했습니다." -ForegroundColor Green
    }

    if (-not (Test-Path $exePath)) {
        Write-Host "[오류] 실행 파일이 없습니다. 먼저 '0_앱_빌드_및_설치.bat'을 실행해 주세요: $exePath" -ForegroundColor Red
        exit 1
    }

    & $exePath --test-config
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[오류] web-config.json 검증 실패(코드 $LASTEXITCODE)" -ForegroundColor Red
        exit 1
    }

    $cfg = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $port = [int]$cfg.ListenPort
    if ($port -lt 1024 -or $port -gt 65535) { $port = 18080 }

    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    New-NetFirewallRule `
        -DisplayName $ruleName `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $port `
        -Profile Private,Public `
        -Description "RemotePowerWeb 모바일 원클릭 전원 제어 서버 인바운드 허용" | Out-Null
    Write-Host "[방화벽 완료] TCP $port 포트 인바운드 허용됨" -ForegroundColor Green

    if ($null -ne (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    $action = New-ScheduledTaskAction -Execute $exePath -WorkingDirectory $webDir
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT5S'

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
        -Description "모바일 원클릭 전원 제어 웹 서버(RemotePowerWeb)" | Out-Null

    Write-Host "[작업 등록 완료] '$taskName'" -ForegroundColor Green

    if ([string]::IsNullOrWhiteSpace($TargetUser)) {
        $TargetUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    }
    if ([string]::IsNullOrWhiteSpace($AntigravityExe) -or -not (Test-Path $AntigravityExe)) {
        $foundAgy = Get-ChildItem "C:\Users\*\AppData\Local\Programs\antigravity\Antigravity.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
        if ($foundAgy) { $AntigravityExe = $foundAgy }
    }

    if (-not [string]::IsNullOrWhiteSpace($TargetUser) -and -not [string]::IsNullOrWhiteSpace($AntigravityExe) -and (Test-Path $AntigravityExe)) {
        $existingAgy = Get-ScheduledTask -TaskName $agyTaskName -ErrorAction SilentlyContinue
        if ($null -ne $existingAgy) {
            Unregister-ScheduledTask -TaskName $agyTaskName -Confirm:$false
        }

        $agyDir = Split-Path -Parent $AntigravityExe
        $agyAction = New-ScheduledTaskAction -Execute $AntigravityExe -WorkingDirectory $agyDir
        $agyPrincipal = New-ScheduledTaskPrincipal -UserId $TargetUser -LogonType Interactive -RunLevel Limited
        $agySettings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
            -MultipleInstances IgnoreNew

        Register-ScheduledTask `
            -TaskName $agyTaskName `
            -Action $agyAction `
            -Principal $agyPrincipal `
            -Settings $agySettings `
            -Description "RemotePowerWeb에서 사용자 세션($TargetUser)으로 Antigravity 앱을 실행합니다." | Out-Null

        Write-Host "[작업 등록 완료] '$agyTaskName' (대상: $TargetUser)" -ForegroundColor Green
    }
    else {
        Write-Host "[참고] Antigravity 실행 파일 또는 대상 사용자를 찾지 못해 '$agyTaskName' 등록을 건너뛰었습니다." -ForegroundColor Yellow
    }

    Start-ScheduledTask -TaskName $taskName
    Start-Sleep -Seconds 3

    $taskInfo = Get-ScheduledTask -TaskName $taskName
    Write-Host "현재 작업 상태: $($taskInfo.State)" -ForegroundColor Cyan

    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/health" -TimeoutSec 3
        Write-Host "[동작 확인 완료] http://127.0.0.1:$port/api/health -> ok=$($health.ok)" -ForegroundColor Green
    }
    catch {
        Write-Host "[참고] 헬스 체크 대기 중: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    if (Test-Path $logPath) {
        Write-Host ""
        Write-Host "=== 최근 웹 서버 로그 (logs\web.log) ===" -ForegroundColor Cyan
        Get-Content -Path $logPath -Tail 8 -Encoding UTF8
    }
}
finally {
    Stop-Transcript | Out-Null
}
