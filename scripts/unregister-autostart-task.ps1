<#
.SYNOPSIS
    등록된 PCRemotePowerBot 자동 실행 작업을 중지하고 삭제합니다.
#>
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    $proc = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs -Wait -PassThru
    exit $proc.ExitCode
}

$taskName = "PCRemotePowerBot"
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -eq $existing) {
    Write-Host "등록된 '$taskName' 작업이 없습니다."
    exit 0
}

Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
Write-Host "[제거 완료] '$taskName' 자동 실행 작업을 삭제했습니다." -ForegroundColor Green
