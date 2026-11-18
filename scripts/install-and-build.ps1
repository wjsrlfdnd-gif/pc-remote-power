<#
.SYNOPSIS
    저장소를 내려받은 PC에서 RemotePowerWeb 및 RemotePowerBot을 빌드하고 실행 파일을 생성합니다.
#>
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$projectRoot = Split-Path -Parent $PSScriptRoot
$webProj = Join-Path $projectRoot "RemotePowerWeb\RemotePowerWeb.csproj"
$botProj = Join-Path $projectRoot "RemotePowerBot\RemotePowerBot.csproj"
$webOut = Join-Path $projectRoot "web-app"
$webStaging = Join-Path $projectRoot "web-app-staging"
$botOut = Join-Path $projectRoot "app"
$botStaging = Join-Path $projectRoot "app-staging"

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  PC 원격 전원 관리 앱 빌드 및 설치 준비" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

$dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
if ($null -eq $dotnetCmd) {
    Write-Host "[안내] .NET SDK가 설치되어 있지 않습니다. winget으로 .NET 9 SDK 설치를 시도합니다..." -ForegroundColor Yellow
    & winget.exe install --source winget --id Microsoft.DotNet.SDK.9 --exact --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[오류] .NET SDK 설치에 실패했습니다. https://dotnet.microsoft.com/download/dotnet/9.0 에서 설치 후 다시 실행하세요." -ForegroundColor Red
        exit 1
    }
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}

$sdks = & dotnet --list-sdks 2>$null
Write-Host "감지된 .NET SDK:" -ForegroundColor Green
$sdks | ForEach-Object { Write-Host "  - $_" }

# RemotePowerWeb 게시
$webTarget = if (Get-Process -Name "RemotePowerWeb" -ErrorAction SilentlyContinue) { $webStaging } else { $webOut }
Write-Host ""
Write-Host "[1/2] RemotePowerWeb 빌드 중 -> $webTarget" -ForegroundColor Cyan
& dotnet publish $webProj -c Release -o $webTarget
if ($LASTEXITCODE -ne 0) {
    Write-Host "[오류] RemotePowerWeb 빌드에 실패했습니다." -ForegroundColor Red
    exit 1
}

# RemotePowerBot 게시
$botTarget = if (Get-Process -Name "RemotePowerBot" -ErrorAction SilentlyContinue) { $botStaging } else { $botOut }
Write-Host ""
Write-Host "[2/2] RemotePowerBot 빌드 중 -> $botTarget" -ForegroundColor Cyan
& dotnet publish $botProj -c Release -o $botTarget
if ($LASTEXITCODE -ne 0) {
    Write-Host "[오류] RemotePowerBot 빌드에 실패했습니다." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== 빌드 검증 (--test-status) ===" -ForegroundColor Cyan
& (Join-Path $webTarget "RemotePowerWeb.exe") --test-status
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host ""
Write-Host "[완료] 빌드가 성공적으로 끝났습니다!" -ForegroundColor Green
Write-Host "다음 순서로 실행하세요:" -ForegroundColor Yellow
Write-Host "  1) 1_Windows_WOL_설정(관리자).bat"
Write-Host "  2) 2_폰_원클릭_웹_설정.bat"
Write-Host "  3) 3_웹_자동실행_방화벽_등록(관리자).bat"
Write-Host "  4) 4_Tailscale_원격데스크톱_설정(관리자).bat (원격 화면 제어 필요 시)"
