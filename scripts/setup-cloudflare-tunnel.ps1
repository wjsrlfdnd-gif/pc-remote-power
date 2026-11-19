<#
.SYNOPSIS
    VPN이나 공유기 포트포워딩 없이 Windows PC(RemotePowerWeb)를 안전한 HTTPS로 외부에 연결하기 위해
    Cloudflare Tunnel(cloudflared)을 자동 설치하고 부팅 자동 실행 작업(PCRemotePowerTunnel)으로 등록합니다.
#>
param(
    [string]$Mode = "",
    [string]$TunnelToken = "",
    [string]$PublicUrl = "",
    [string]$WebhookUrl = ""
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

$taskName = "PCRemotePowerTunnel"
$projectRoot = Split-Path -Parent $PSScriptRoot
$webConfigPath = Join-Path $projectRoot "web-config.json"
$tunnelConfigPath = Join-Path $projectRoot "tunnel-config.json"
$runnerScriptPath = Join-Path $projectRoot "scripts\run-cloudflare-tunnel.ps1"
$toolsDir = Join-Path $projectRoot "tools"
$localCfExe = Join-Path $toolsDir "cloudflared.exe"
$setupLogPath = Join-Path $projectRoot "logs\cloudflare-tunnel-setup.log"
$urlFilePath = Join-Path $projectRoot "logs\cloudflare-tunnel-url.txt"
$pwaBaseUrl = "https://wjsrlfdnd-gif.github.io/pc-remote-power/"

function Find-CloudflaredExe {
    $cmd = Get-Command cloudflared.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
        $localCfExe,
        "C:\Program Files (x86)\cloudflared\cloudflared.exe",
        "C:\Program Files\cloudflared\cloudflared.exe"
    )) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

# 1. 관리자 승격 전에 대화형 입력을 먼저 수집 (승격 창이 닫혀도 터미널에서 바로 입력/결과 확인 가능)
if ([string]::IsNullOrWhiteSpace($Mode)) {
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  VPN 없이 외부 접속 설정 (Cloudflare Tunnel 자동 HTTPS)" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "※ 참고: 집 안 상시 중계기(공기계/라즈베리파이)로 WoL 켜기까지 쓰신다면" -ForegroundColor Yellow
    Write-Host "   중계기에서 'bash relay/setup_relay_cloudflare.sh'를 실행하세요." -ForegroundColor Yellow
    Write-Host "   이 스크립트는 Windows PC 자체를 VPN 없이 외부 HTTPS로 연결합니다." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "연결 방식을 선택하세요:" -ForegroundColor White
    Write-Host "  1) Quick Tunnel  - 계정·도메인 없이 즉시 무료 HTTPS 발급 (재부팅 시 주소 변경)" -ForegroundColor Green
    Write-Host "  2) Named Tunnel  - 무료 Cloudflare 계정 + 영구 고정 HTTPS 주소 (상시 추천)" -ForegroundColor Cyan
    Write-Host ""

    $choice = (Read-Host "선택 [1 또는 2, 기본값: 1]").Trim()
    if ($choice -eq "2") {
        $Mode = "token"
        $TunnelToken = (Read-Host "Cloudflare Zero Trust 터널 토큰 입력 (eyJh...)").Trim().Trim('"')
        while ([string]::IsNullOrWhiteSpace($TunnelToken)) {
            $TunnelToken = (Read-Host "터널 토큰은 필수입니다").Trim().Trim('"')
        }
        $PublicUrl = (Read-Host "연결한 고정 HTTPS 주소 입력 (예: https://pc.mydomain.com, 선택)").Trim().TrimEnd('/')
    }
    else {
        $Mode = "quick"
        Write-Host ""
        Write-Host "(선택) PC 재부팅 시 바뀌는 Quick Tunnel 새 주소를 폰으로 자동 알림 받으려면" -ForegroundColor DarkGray
        Write-Host "Discord Webhook URL 또는 ntfy.sh 주소(예: https://ntfy.sh/비밀토픽)를 입력하세요." -ForegroundColor DarkGray
        $WebhookUrl = (Read-Host "알림 웹훅 URL (미사용 시 그냥 엔터)").Trim()
    }
}

if (-not $isAdmin) {
    $targetPort = 18080
    $pcName = $env:COMPUTERNAME
    if (Test-Path $webConfigPath) {
        $wcfg = Get-Content -Path $webConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($wcfg.ListenPort) { $targetPort = [int]$wcfg.ListenPort }
        if ($wcfg.PcDisplayName) { $pcName = $wcfg.PcDisplayName.ToString() }
    }

    # 민감한 토큰을 명령줄 인자로 넘기지 않도록 tunnel-config.json에 먼저 저장
    $preCfg = [ordered]@{
        TunnelMode = $Mode
        TargetPort = $targetPort
        PcDisplayName = $pcName
        TunnelToken = $TunnelToken
        PublicUrl = $PublicUrl
        NotifyWebhookUrl = $WebhookUrl
        CloudflaredPath = ""
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tunnelConfigPath, ($preCfg | ConvertTo-Json -Depth 4), $utf8NoBom)

    Write-Host ""
    Write-Host "cloudflared 설치 및 부팅 자동 실행 등록을 위해 관리자 권한 UAC 창을 띄웁니다..." -ForegroundColor Cyan
    try {
        $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode `"$Mode`""
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs -Wait -PassThru
        if (Test-Path $setupLogPath) {
            Write-Host ""
            Get-Content -Path $setupLogPath -Encoding UTF8 | Select-Object -Last 35 | ForEach-Object { Write-Host $_ }
        }
        if (Test-Path $urlFilePath) {
            $uLines = Get-Content -Path $urlFilePath -Encoding UTF8
            if ($uLines.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($uLines[1])) {
                $clipLink = $uLines[1].Trim()
                if ((Test-Path $webConfigPath)) {
                    $wcfg2 = Get-Content -Path $webConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($wcfg2.ApiToken) {
                        $clipLink = "$clipLink&token=$([Uri]::EscapeDataString($wcfg2.ApiToken.ToString()))"
                    }
                }
                try { Set-Clipboard -Value $clipLink -ErrorAction SilentlyContinue } catch {}
            }
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
    # 구버전 중복 배치 파일 자동 정리
    $legacyBat = Join-Path $projectRoot "4_Tailscale_원격데스크톱_설정(관리자).bat"
    $newOptionalBat = Join-Path $projectRoot "optional_Tailscale_원격데스크톱_설정(관리자).bat"
    if ((Test-Path $legacyBat) -and (Test-Path $newOptionalBat)) {
        Remove-Item -Path $legacyBat -Force -ErrorAction SilentlyContinue
        Write-Host "[정리 완료] 이전 버전의 중복 파일(4_Tailscale_...bat)을 정리했습니다." -ForegroundColor Green
    }

    $targetPort = 18080
    $pcName = $env:COMPUTERNAME
    $apiToken = ""
    if (Test-Path $webConfigPath) {
        $wcfg = Get-Content -Path $webConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($wcfg.ListenPort) { $targetPort = [int]$wcfg.ListenPort }
        if ($wcfg.PcDisplayName) { $pcName = $wcfg.PcDisplayName.ToString() }
        if ($wcfg.ApiToken) { $apiToken = $wcfg.ApiToken.ToString() }
    }

    # RemotePowerWeb 최신 코드 자동 반영 및 백그라운드 웹 서버 기동 확인
    $webTaskName = "PCRemotePowerWeb"
    $webProj = Join-Path $projectRoot "RemotePowerWeb\RemotePowerWeb.csproj"
    $webDir = Join-Path $projectRoot "web-app"
    $stagingDir = Join-Path $projectRoot "web-app-staging"
    $dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($null -ne $dotnetCmd -and (Test-Path $webProj)) {
        Write-Host "[자동 업데이트] RemotePowerWeb 최신 보안 패치 빌드 중..." -ForegroundColor Cyan
        & dotnet publish $webProj -c Release -o $stagingDir --nologo -v q
    }
    if (Test-Path $stagingDir) {
        Stop-ScheduledTask -TaskName $webTaskName -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 700
        Get-Process -Name "RemotePowerWeb" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
        if (-not (Test-Path $webDir)) { New-Item -ItemType Directory -Path $webDir -Force | Out-Null }
        Copy-Item -Path (Join-Path $stagingDir "*") -Destination $webDir -Recurse -Force
        Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[자동 업데이트 완료] 최신 RemotePowerWeb 빌드를 web-app에 반영했습니다." -ForegroundColor Green
    }
    if ($null -ne (Get-ScheduledTask -TaskName $webTaskName -ErrorAction SilentlyContinue)) {
        Start-ScheduledTask -TaskName $webTaskName -ErrorAction SilentlyContinue
    }

    # 기존 tunnel-config.json이 있으면 로드 (비승격 단계에서 저장된 값 유지)
    if (Test-Path $tunnelConfigPath) {
        $saved = Get-Content -Path $tunnelConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace($TunnelToken) -and $saved.TunnelToken) { $TunnelToken = $saved.TunnelToken.ToString() }
        if ([string]::IsNullOrWhiteSpace($PublicUrl) -and $saved.PublicUrl) { $PublicUrl = $saved.PublicUrl.ToString() }
        if ([string]::IsNullOrWhiteSpace($WebhookUrl) -and $saved.NotifyWebhookUrl) { $WebhookUrl = $saved.NotifyWebhookUrl.ToString() }
        if ([string]::IsNullOrWhiteSpace($Mode) -and $saved.TunnelMode) { $Mode = $saved.TunnelMode.ToString() }
    }

    # 2. cloudflared 설치 확인 (winget -> 실패 시 GitHub 공식 바이너리 직접 다운로드)
    $cfExe = Find-CloudflaredExe
    if (-not $cfExe) {
        Write-Host "[설치] cloudflared가 없어 winget으로 설치를 시도합니다..." -ForegroundColor Yellow
        try {
            & winget.exe install --source winget --id Cloudflare.cloudflared --exact --accept-source-agreements --accept-package-agreements
        }
        catch {}
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        $cfExe = Find-CloudflaredExe
    }

    if (-not $cfExe) {
        Write-Host "[설치] 공식 GitHub 릴리스에서 cloudflared-windows-amd64.exe를 직접 다운로드합니다..." -ForegroundColor Yellow
        if (-not (Test-Path $toolsDir)) { New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null }
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
        $dlUrl = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
        Invoke-WebRequest -Uri $dlUrl -OutFile $localCfExe -UseBasicParsing
        $cfExe = $localCfExe
    }

    if (-not $cfExe -or -not (Test-Path $cfExe)) {
        Write-Host "[오류] cloudflared 설치에 실패했습니다. https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/ 에서 설치 후 다시 실행해 주세요." -ForegroundColor Red
        exit 1
    }
    Write-Host "[확인] cloudflared 경로: $cfExe" -ForegroundColor Green

    # 3. tunnel-config.json 최종 저장
    $finalCfg = [ordered]@{
        TunnelMode = $Mode
        TargetPort = $targetPort
        PcDisplayName = $pcName
        TunnelToken = $TunnelToken
        PublicUrl = $PublicUrl
        NotifyWebhookUrl = $WebhookUrl
        CloudflaredPath = $cfExe
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tunnelConfigPath, ($finalCfg | ConvertTo-Json -Depth 4), $utf8NoBom)
    Write-Host "[저장 완료] $tunnelConfigPath" -ForegroundColor Green

    # 4. 기존 작업 중지 및 교체
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    Get-Process -Name "cloudflared" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    if (Test-Path $urlFilePath) { Remove-Item -Path $urlFilePath -Force -ErrorAction SilentlyContinue }

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runnerScriptPath`"" `
        -WorkingDirectory $projectRoot
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT10S'

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
        -Description "VPN 없이 Cloudflare Tunnel(cloudflared)로 RemotePowerWeb 외부 HTTPS 접속을 제공합니다." | Out-Null

    Write-Host "[작업 등록 완료] '$taskName' (부팅 시 자동 실행)" -ForegroundColor Green
    Start-ScheduledTask -TaskName $taskName

    if ($Mode -eq "quick") {
        Write-Host "무료 HTTPS 주소 발급 대기 중 (최대 15초)..." -ForegroundColor Cyan
        $foundLines = $null
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Seconds 1
            if (Test-Path $urlFilePath) {
                $foundLines = Get-Content -Path $urlFilePath -Encoding UTF8
                if ($foundLines.Count -ge 1 -and -not [string]::IsNullOrWhiteSpace($foundLines[0])) { break }
            }
        }

        if ($foundLines -and $foundLines.Count -ge 1) {
            $liveUrl = $foundLines[0].Trim()
            $pwaLink = if ($foundLines.Count -ge 2) { $foundLines[1].Trim() } else { "${pwaBaseUrl}?server=$([Uri]::EscapeDataString($liveUrl))&mode=direct" }
            $fullOneClickLink = if (-not [string]::IsNullOrWhiteSpace($apiToken)) {
                "$pwaLink&token=$([Uri]::EscapeDataString($apiToken))"
            } else {
                $pwaLink
            }
            try { Set-Clipboard -Value $fullOneClickLink -ErrorAction SilentlyContinue } catch {}
            Write-Host ""
            Write-Host "==================== VPN 없이 외부 접속 준비 완료 ====================" -ForegroundColor Yellow
            Write-Host "  HTTPS 서버 주소    : $liveUrl" -ForegroundColor Cyan
            Write-Host "  폰 원클릭 자동설정 : $fullOneClickLink" -ForegroundColor Green
            Write-Host "  (위 원클릭 링크가 클립보드에 자동 복사되었습니다! 카톡 나에게 보내기로 폰에서 여세요)" -ForegroundColor White
            Write-Host "======================================================================" -ForegroundColor Yellow
        }
        else {
            Write-Host "[참고] 주소 발급에 시간이 걸리고 있습니다. 잠시 후 logs\cloudflare-tunnel-url.txt 또는 logs\cloudflare-tunnel.log를 확인하세요." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host ""
        Write-Host "==================== Named Tunnel 등록 완료 ====================" -ForegroundColor Yellow
        Write-Host "  Cloudflare Zero Trust 대시보드에서 이 터널의 Public Hostname을" -ForegroundColor White
        Write-Host "  Service: HTTP / URL: 127.0.0.1:$targetPort 로 연결해 두시면 됩니다." -ForegroundColor Cyan
        if (-not [string]::IsNullOrWhiteSpace($PublicUrl)) {
            $pwaLink = "${pwaBaseUrl}?server=$([Uri]::EscapeDataString($PublicUrl))&mode=direct&name=$([Uri]::EscapeDataString($pcName))"
            $fullOneClickLink = if (-not [string]::IsNullOrWhiteSpace($apiToken)) {
                "$pwaLink&token=$([Uri]::EscapeDataString($apiToken))"
            } else {
                $pwaLink
            }
            try { Set-Clipboard -Value $fullOneClickLink -ErrorAction SilentlyContinue } catch {}
            Write-Host "  폰 원클릭 자동설정 : $fullOneClickLink" -ForegroundColor Green
            Write-Host "  (클립보드에 자동 복사됨)" -ForegroundColor White
        }
        Write-Host "================================================================" -ForegroundColor Yellow
    }
}
finally {
    Stop-Transcript | Out-Null
}
