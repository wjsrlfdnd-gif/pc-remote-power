<#
.SYNOPSIS
    Tailscale 설치 및 Windows 11 Pro 원격 데스크톱(RDP + Windows Hello 전용 제한 해제) 설정을 일괄 적용합니다.
#>
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

$projectRoot = Split-Path -Parent $PSScriptRoot
$setupLogPath = Join-Path $projectRoot "logs\tailscale-rdp-setup.log"
$tailscaleExe = "C:\Program Files\Tailscale\tailscale.exe"
$tailscaleGui = "C:\Program Files\Tailscale\tailscale-ipn.exe"

if (-not $isAdmin) {
    Write-Host "Tailscale 설치 및 Windows 원격 데스크톱 설정을 위해 관리자 권한 UAC 창을 띄웁니다..."
    try {
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs -Wait -PassThru
        if (Test-Path $setupLogPath) {
            Write-Host ""
            Get-Content -Path $setupLogPath -Encoding UTF8 | Select-Object -Last 35 | ForEach-Object { Write-Host $_ }
        }
        # 일반 사용자 세션에서 트레이 앱(tailscale-ipn.exe) 실행 보장
        if ((Test-Path $tailscaleGui) -and -not (Get-Process -Name "tailscale-ipn" -ErrorAction SilentlyContinue)) {
            Start-Process -FilePath $tailscaleGui
            Write-Host ""
            Write-Host "[안내] 작업 표시줄 오른쪽 트레이에 Tailscale 아이콘이 실행되었습니다." -ForegroundColor Cyan
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
    Write-Host "=== Tailscale + Windows App(RDP) 설정 시작 ===" -ForegroundColor Cyan

    # 1. Tailscale 설치 확인 및 winget 설치
    if (-not (Test-Path $tailscaleExe)) {
        Write-Host "Tailscale이 설치되어 있지 않아 winget으로 설치합니다..."
        & winget.exe install --source winget --id Tailscale.Tailscale --exact --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tailscaleExe)) {
            Write-Host "[경고] winget 설치가 완료되지 않았습니다(종료 코드: $LASTEXITCODE). https://tailscale.com/download/windows 에서 직접 설치할 수 있습니다." -ForegroundColor Yellow
        }
        else {
            Write-Host "[설치 완료] Tailscale 설치 성공" -ForegroundColor Green
        }
    }
    else {
        Write-Host "[확인] Tailscale이 이미 설치되어 있습니다." -ForegroundColor Green
    }

    # 2. Windows 원격 데스크톱(RDP) 및 서비스 활성화
    $tsReg = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    $rdpTcpReg = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'

    Set-ItemProperty -Path $tsReg -Name 'fDenyTSConnections' -Value 0 -Type DWord -ErrorAction Stop
    Set-ItemProperty -Path $rdpTcpReg -Name 'UserAuthentication' -Value 1 -Type DWord -ErrorAction Stop
    Write-Host "[RDP 설정] 원격 데스크톱 허용(fDenyTSConnections=0) 및 NLA(UserAuthentication=1) 확인 완료" -ForegroundColor Green

    Set-Service -Name 'TermService' -StartupType Automatic -ErrorAction SilentlyContinue
    $tsSvc = Get-Service -Name 'TermService' -ErrorAction SilentlyContinue
    if ($tsSvc -and $tsSvc.Status -ne 'Running') {
        Start-Service -Name 'TermService' -ErrorAction SilentlyContinue
    }
    $tsSvcAfter = Get-Service -Name 'TermService' -ErrorAction SilentlyContinue
    Write-Host "[서비스] TermService 상태=$($tsSvcAfter.Status), 시작유형=$($tsSvcAfter.StartType)" -ForegroundColor Green

    # 3. 방화벽 원격 데스크톱 규칙 활성화 (Tailscale 가상 어댑터 포함 모든 프로필 허용)
    foreach ($ruleName in @('RemoteDesktop-UserMode-In-TCP', 'RemoteDesktop-UserMode-In-UDP')) {
        $rule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
        if ($null -ne $rule) {
            Enable-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
            Write-Host "[방화벽] $ruleName 활성화 확인" -ForegroundColor Green
        }
    }

    # 4. Windows Hello 전용 로그인 제한 해제 (Microsoft 계정 비밀번호로 RDP 로그인 허용)
    $pwLessReg = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
    if (Test-Path $pwLessReg) {
        $beforePwLess = (Get-ItemProperty -Path $pwLessReg -Name 'DevicePasswordLessBuildVersion' -ErrorAction SilentlyContinue).DevicePasswordLessBuildVersion
        Set-ItemProperty -Path $pwLessReg -Name 'DevicePasswordLessBuildVersion' -Value 0 -Type DWord -ErrorAction SilentlyContinue
        $afterPwLess = (Get-ItemProperty -Path $pwLessReg -Name 'DevicePasswordLessBuildVersion' -ErrorAction SilentlyContinue).DevicePasswordLessBuildVersion
        Write-Host "[로그인 호환성] Windows Hello 전용 제한 해제(DevicePasswordLessBuildVersion: $beforePwLess -> $afterPwLess)" -ForegroundColor Green
    }

    # 5. Tailscale 서비스 및 무인 실행(Unattended) 설정
    if (Test-Path $tailscaleExe) {
        $tailSvc = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
        if ($tailSvc) {
            Set-Service -Name 'Tailscale' -StartupType Automatic -ErrorAction SilentlyContinue
            if ($tailSvc.Status -ne 'Running') {
                Start-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
        }

        try {
            & $tailscaleExe set --unattended=true 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[Tailscale] 무인 자동 실행 모드(--unattended=true) 활성화 완료" -ForegroundColor Green
            }
        }
        catch {}

        $tsIp = (& $tailscaleExe ip -4 2>$null | Select-Object -First 1)
        if (-not [string]::IsNullOrWhiteSpace($tsIp)) {
            Write-Host ""
            Write-Host "======================================================" -ForegroundColor Yellow
            Write-Host "  Tailscale 연결 완료! 이 PC의 Tailscale IP: $tsIp" -ForegroundColor Cyan
            Write-Host "======================================================" -ForegroundColor Yellow
        }
        else {
            Write-Host ""
            Write-Host "[다음 단계] 작업 표시줄 오른쪽 트레이의 Tailscale 아이콘을 눌러 로그인해 주세요." -ForegroundColor Yellow
            Write-Host "로그인 후 트레이 아이콘 우클릭 -> Preferences -> 'Run unattended' 체크를 확인하세요." -ForegroundColor Yellow
        }
    }

    Write-Host "=== Tailscale + Windows App(RDP) 설정 완료 ===" -ForegroundColor Cyan
}
finally {
    Stop-Transcript | Out-Null
}
