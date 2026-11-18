<#
.SYNOPSIS
    Discord 봇 토큰, 알림 채널 ID, 허용 사용자 ID를 검증하고 config.json을 생성합니다.
#>
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$projectRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $projectRoot "config.json"
$exePath = Join-Path $projectRoot "app\RemotePowerBot.exe"

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Discord 원격 전원 제어 봇 설정 마법사" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "준비물:" -ForegroundColor Yellow
Write-Host "  1) Discord Developer Portal에서 발급받은 Bot Token"
Write-Host "  2) 알림/버튼 패널을 받을 디스코드 텍스트 채널 ID"
Write-Host "  3) 전원을 제어할 본인 디스코드 사용자 ID (개발자 모드 켜기 후 프로필 우클릭 -> 사용자 ID 복사)"
Write-Host ""

$botToken = (Read-Host "1) Discord Bot Token을 입력하세요").Trim().Trim('"').Trim("'")
if ([string]::IsNullOrWhiteSpace($botToken)) {
    Write-Host "[오류] Bot Token이 비어 있습니다." -ForegroundColor Red
    exit 1
}

# Discord API로 Bot Token 유효성 확인
$headers = @{ Authorization = "Bot $botToken" }
try {
    $botUser = Invoke-RestMethod -Uri "https://discord.com/api/v10/users/@me" -Headers $headers -Method Get
    Write-Host "[확인] 봇 인증 성공: $($botUser.username) (Bot ID: $($botUser.id))" -ForegroundColor Green
}
catch {
    Write-Host "[오류] Bot Token이 올바르지 않거나 Discord API 연결에 실패했습니다: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# 봇이 속한 서버 확인 및 미초대 시 초대 링크 안내
try {
    $guilds = Invoke-RestMethod -Uri "https://discord.com/api/v10/users/@me/guilds" -Headers $headers -Method Get
    if ($guilds.Count -eq 0) {
        # VIEW_CHANNEL(1024) + SEND_MESSAGES(2048) + EMBED_LINKS(16384) + READ_MESSAGE_HISTORY(65536) + USE_APPLICATION_COMMANDS(2147483648)
        $inviteUrl = "https://discord.com/oauth2/authorize?client_id=$($botUser.id)&permissions=2147567616&scope=bot%20applications.commands"
        Write-Host ""
        Write-Host "[안내] 봇이 아직 어떤 서버에도 초대되지 않았습니다!" -ForegroundColor Yellow
        Write-Host "아래 링크를 브라우저에 열어 본인 개인 서버에 봇을 먼저 초대해 주세요:" -ForegroundColor Yellow
        Write-Host $inviteUrl -ForegroundColor White
        Write-Host ""
        Read-Host "서버에 봇 초대를 완료했으면 Enter 키를 누르세요"
    }
    else {
        Write-Host "[확인] 현재 참여 중인 서버: $(($guilds | ForEach-Object { $_.name }) -join ', ')" -ForegroundColor Green
    }
}
catch {
    Write-Host "[참고] 서버 목록 조회 건너뜀: $($_.Exception.Message)" -ForegroundColor DarkYellow
}

$channelIdRaw = (Read-Host "2) 부팅 알림 및 제어 패널을 올릴 디스코드 채널 ID (숫자)").Trim()
[uint64]$channelId = 0
if (-not [uint64]::TryParse($channelIdRaw, [ref]$channelId) -or $channelId -eq 0) {
    Write-Host "[오류] 올바른 숫자 형식의 채널 ID가 아닙니다." -ForegroundColor Red
    exit 1
}

try {
    $channelInfo = Invoke-RestMethod -Uri "https://discord.com/api/v10/channels/$channelId" -Headers $headers -Method Get
    Write-Host "[확인] 채널 연결 확인됨: #$($channelInfo.name) ($($channelInfo.id))" -ForegroundColor Green
}
catch {
    Write-Host "[경고] 봇이 해당 채널($channelId)에 접근하지 못했습니다. 봇을 서버에 초대했고 해당 채널 보기/보내기 권한이 있는지 확인하세요." -ForegroundColor Yellow
}

$usersRaw = (Read-Host "3) 명령을 허용할 본인 디스코드 사용자 ID (여러 명이면 쉼표로 구분)").Trim()
$allowedUsers = @()
foreach ($part in ($usersRaw -split ',')) {
    $trimmed = $part.Trim()
    [uint64]$uid = 0
    if ([uint64]::TryParse($trimmed, [ref]$uid) -and $uid -gt 0) {
        $allowedUsers += $uid
    }
}
if ($allowedUsers.Count -eq 0) {
    Write-Host "[오류] 유효한 사용자 ID가 최소 1개 이상 필요합니다." -ForegroundColor Red
    exit 1
}

$pcName = (Read-Host "4) 디스코드에 표시할 PC 이름 [기본값: $env:COMPUTERNAME]").Trim()
if ([string]::IsNullOrWhiteSpace($pcName)) {
    $pcName = $env:COMPUTERNAME
}

$delayRaw = (Read-Host "5) 종료/재부팅 대기 시간(초) [기본값: 10]").Trim()
$delaySec = 10
if (-not [string]::IsNullOrWhiteSpace($delayRaw)) {
    [int]$parsedDelay = 10
    if ([int]::TryParse($delayRaw, [ref]$parsedDelay) -and $parsedDelay -ge 0 -and $parsedDelay -le 3600) {
        $delaySec = $parsedDelay
    }
}

$configObj = [ordered]@{
    BotToken = $botToken
    NotifyChannelId = $channelId
    AllowedUserIds = @($allowedUsers)
    ShutdownDelaySeconds = $delaySec
    SendBootNotification = $true
    PcDisplayName = $pcName
}

$jsonText = $configObj | ConvertTo-Json -Depth 4
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($configPath, $jsonText, $utf8NoBom)

Write-Host ""
Write-Host "[저장 완료] $configPath" -ForegroundColor Green

if (Test-Path $exePath) {
    & $exePath --test-config
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[검증 성공] config.json 설정이 유효합니다!" -ForegroundColor Green
        Write-Host "이제 'scripts\3-register-autostart-task.ps1'을 관리자 권한으로 실행하면 부팅 직후부터 자동으로 봇이 실행됩니다." -ForegroundColor Cyan
    }
    else {
        Write-Host "[경고] 설정 검증에서 오류가 반환되었습니다(코드 $LASTEXITCODE)." -ForegroundColor Red
    }
}
