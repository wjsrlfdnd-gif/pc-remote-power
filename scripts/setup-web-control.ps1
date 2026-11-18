<#
.SYNOPSIS
    모바일 원클릭 웹 제어 서버(RemotePowerWeb)용 web-config.json을 생성하고 접속 URL/단축어 정보를 안내합니다.
#>
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$projectRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $projectRoot "web-config.json"
$exePath = Join-Path $projectRoot "web-app\RemotePowerWeb.exe"

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  스마트폰 원클릭 원격 제어 웹 서버 설정" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

$bytes = New-Object byte[] 24
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($bytes)
$defaultToken = ([Convert]::ToBase64String($bytes)).Replace('+', '-').Replace('/', '_').TrimEnd('=')

$portRaw = (Read-Host "1) 웹 서버 포트 번호 [기본값: 18080]").Trim()
$listenPort = 18080
if (-not [string]::IsNullOrWhiteSpace($portRaw)) {
    [int]$parsedPort = 18080
    if ([int]::TryParse($portRaw, [ref]$parsedPort) -and $parsedPort -ge 1024 -and $parsedPort -le 65535) {
        $listenPort = $parsedPort
    }
}

$tokenInput = (Read-Host "2) 인증용 ApiToken (비워두고 엔터 시 강력한 랜덤 토큰 자동 생성)").Trim()
$apiToken = if ([string]::IsNullOrWhiteSpace($tokenInput)) { $defaultToken } else { $tokenInput }

$pcName = (Read-Host "3) 모바일 화면에 표시할 PC 이름 [기본값: $env:COMPUTERNAME]").Trim()
if ([string]::IsNullOrWhiteSpace($pcName)) {
    $pcName = $env:COMPUTERNAME
}

$delayRaw = (Read-Host "4) 종료/재부팅 대기 시간(초) [기본값: 5]").Trim()
$delaySec = 5
if (-not [string]::IsNullOrWhiteSpace($delayRaw)) {
    [int]$parsedDelay = 5
    if ([int]::TryParse($delayRaw, [ref]$parsedDelay) -and $parsedDelay -ge 0 -and $parsedDelay -le 3600) {
        $delaySec = $parsedDelay
    }
}

$duckDomain = (Read-Host "5) DuckDNS 도메인 (예: mypc, 미사용 시 그냥 엔터)").Trim()
$duckToken = ""
if (-not [string]::IsNullOrWhiteSpace($duckDomain)) {
    $duckToken = (Read-Host "   DuckDNS Token 입력").Trim()
}

$configObj = [ordered]@{
    ListenPort = $listenPort
    ApiToken = $apiToken
    PcDisplayName = $pcName
    ShutdownDelaySeconds = $delaySec
    DuckDnsDomain = $duckDomain
    DuckDnsToken = $duckToken
}

$jsonText = $configObj | ConvertTo-Json -Depth 4
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($configPath, $jsonText, $utf8NoBom)

Write-Host ""
Write-Host "[저장 완료] $configPath" -ForegroundColor Green

if (Test-Path $exePath) {
    & $exePath --test-config
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[경고] web-config.json 검증 실패(코드 $LASTEXITCODE)" -ForegroundColor Red
        exit 1
    }
}

$localIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notmatch '^127\.|^169\.254\.' } |
    Select-Object -First 1 -ExpandProperty IPAddress)
if ([string]::IsNullOrWhiteSpace($localIp)) { $localIp = "127.0.0.1" }

$publicIp = $null
try {
    $publicIp = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 3).ToString().Trim()
} catch {}

Write-Host ""
Write-Host "================ 접속 및 원클릭 정보 ================" -ForegroundColor Yellow
Write-Host "  ApiToken        : $apiToken" -ForegroundColor White
Write-Host "  집 안 Wi-Fi 주소: http://${localIp}:${listenPort}/?token=${apiToken}" -ForegroundColor Cyan
if (-not [string]::IsNullOrWhiteSpace($duckDomain)) {
    $cleanDomain = $duckDomain -replace '\.duckdns\.org$', ''
    Write-Host "  외부 DuckDNS    : http://${cleanDomain}.duckdns.org:${listenPort}/?token=${apiToken}" -ForegroundColor Cyan
}
elseif ($publicIp) {
    Write-Host "  외부 공인 IP    : http://${publicIp}:${listenPort}/?token=${apiToken}" -ForegroundColor Cyan
    Write-Host "  (※ 외부 직접 접속 시 공유기 포트포워딩 TCP $listenPort -> ${localIp}:$listenPort 필요)" -ForegroundColor DarkGray
}
Write-Host "=====================================================" -ForegroundColor Yellow
Write-Host "다음으로 '3_웹_자동실행_방화벽_등록(관리자).bat'을 실행하면 바로 서버가 켜집니다." -ForegroundColor Green
