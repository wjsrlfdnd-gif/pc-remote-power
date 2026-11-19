<#
.SYNOPSIS
    tunnel-config.json 설정에 따라 cloudflared(Quick Tunnel 또는 Named Tunnel)를 상시 실행합니다.
    Quick Tunnel 사용 시 발급된 HTTPS 주소를 logs\cloudflare-tunnel-url.txt에 저장하고, 선택적 웹훅 알림을 전송합니다.
#>
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$projectRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $projectRoot "tunnel-config.json"
$logDir = Join-Path $projectRoot "logs"
$logPath = Join-Path $logDir "cloudflare-tunnel.log"
$urlFilePath = Join-Path $logDir "cloudflare-tunnel-url.txt"
$pwaBaseUrl = "https://wjsrlfdnd-gif.github.io/pc-remote-power/"

if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-TunnelLog {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $logPath -Value $line -Encoding UTF8
}

function Find-CloudflaredExe {
    param([string]$ConfiguredPath)
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($ConfiguredPath)) { $candidates += $ConfiguredPath }
    $cmd = Get-Command cloudflared.exe -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    $candidates += @(
        (Join-Path $projectRoot "tools\cloudflared.exe"),
        "C:\Program Files (x86)\cloudflared\cloudflared.exe",
        "C:\Program Files\cloudflared\cloudflared.exe"
    )
    foreach ($c in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($c) -and (Test-Path $c)) {
            return $c
        }
    }
    return $null
}

function Send-TunnelWebhook {
    param([string]$WebhookUrl, [string]$PcName, [string]$PublicUrl, [string]$PwaLink)
    if ([string]::IsNullOrWhiteSpace($WebhookUrl)) { return }
    try {
        $lower = $WebhookUrl.ToLowerInvariant()
        if ($lower -like "*discord.com/api/webhooks/*" -or $lower -like "*discordapp.com/api/webhooks/*") {
            $body = @{
                content = "⚡ **$PcName 원격 전원 터널 연결 완료 (VPN 불필요)**`n• 서버 주소: $PublicUrl`n• PWA 자동 설정 열기: $PwaLink"
            } | ConvertTo-Json -Compress
            Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 8 | Out-Null
        }
        else {
            $asciiName = ($PcName -replace '[^\x20-\x7E]', '').Trim()
            if ([string]::IsNullOrWhiteSpace($asciiName)) { $asciiName = "PC" }
            $bodyText = "$PcName 원격 전원 터널이 시작되었습니다.`n서버 주소: $PublicUrl`nPWA 열기: $PwaLink"
            Invoke-RestMethod -Uri $WebhookUrl -Method Post -Headers @{ Title = "$asciiName Remote Power"; Click = $PwaLink } -ContentType "text/plain; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($bodyText)) -TimeoutSec 8 | Out-Null
        }
        Write-TunnelLog "[알림 전송 완료] $PublicUrl"
    }
    catch {
        Write-TunnelLog "[알림 전송 실패] $($_.Exception.Message)"
    }
}

if (-not (Test-Path $configPath)) {
    Write-TunnelLog "[오류] tunnel-config.json을 찾을 수 없습니다: $configPath"
    exit 1
}

$cfg = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$mode = if ($cfg.TunnelMode) { $cfg.TunnelMode.ToString().Trim().ToLowerInvariant() } else { "quick" }
$port = if ($cfg.TargetPort) { [int]$cfg.TargetPort } else { 18080 }
$pcName = if ($cfg.PcDisplayName) { $cfg.PcDisplayName.ToString().Trim() } else { $env:COMPUTERNAME }
$token = if ($cfg.TunnelToken) { $cfg.TunnelToken.ToString().Trim() } else { "" }
$publicUrl = if ($cfg.PublicUrl) { $cfg.PublicUrl.ToString().Trim().TrimEnd('/') } else { "" }
$webhookUrl = if ($cfg.NotifyWebhookUrl) { $cfg.NotifyWebhookUrl.ToString().Trim() } else { "" }

$cfExe = Find-CloudflaredExe -ConfiguredPath $cfg.CloudflaredPath
if (-not $cfExe) {
    Write-TunnelLog "[오류] cloudflared.exe를 찾을 수 없습니다."
    exit 1
}

if ($mode -eq "token") {
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-TunnelLog "[오류] Named Tunnel 토큰이 비어 있습니다."
        exit 1
    }
    if (-not [string]::IsNullOrWhiteSpace($publicUrl)) {
        $pwaLink = "${pwaBaseUrl}?server=$([Uri]::EscapeDataString($publicUrl))&mode=direct&name=$([Uri]::EscapeDataString($pcName))"
        [System.IO.File]::WriteAllText($urlFilePath, "$publicUrl`r`n$pwaLink`r`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    Write-TunnelLog "Named Tunnel 시작: $cfExe"
    & $cfExe tunnel --no-autoupdate run --token $token *>> $logPath
    exit $LASTEXITCODE
}

Write-TunnelLog "Quick Tunnel 시작: http://127.0.0.1:$port"
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $cfExe
$psi.Arguments = "tunnel --no-autoupdate --url http://127.0.0.1:$port"
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $false
$psi.RedirectStandardError = $true

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
$null = $proc.Start()

$lastUrl = ""
$regex = [regex]'https://[a-z0-9-]+\.trycloudflare\.com'

while (-not $proc.HasExited) {
    $line = $proc.StandardError.ReadLine()
    if ($null -eq $line) {
        Start-Sleep -Milliseconds 200
        continue
    }
    Add-Content -Path $logPath -Value $line -Encoding UTF8
    $m = $regex.Match($line)
    if ($m.Success) {
        $found = $m.Value.TrimEnd('/')
        if ($found -ne $lastUrl) {
            $lastUrl = $found
            $pwaLink = "${pwaBaseUrl}?server=$([Uri]::EscapeDataString($found))&mode=direct&name=$([Uri]::EscapeDataString($pcName))"
            [System.IO.File]::WriteAllText($urlFilePath, "$found`r`n$pwaLink`r`n", (New-Object System.Text.UTF8Encoding($false)))
            Write-TunnelLog "[Quick Tunnel 준비 완료] $found"
            Send-TunnelWebhook -WebhookUrl $webhookUrl -PcName $pcName -PublicUrl $found -PwaLink $pwaLink
        }
    }
}

$proc.WaitForExit()
exit $proc.ExitCode
