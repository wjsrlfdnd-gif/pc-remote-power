<#
.SYNOPSIS
    등록된 PCRemotePowerWeb 자동 실행 작업 및 방화벽 규칙을 제거합니다.
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

$taskName = "PCRemotePowerWeb"
$agyTaskName = "LaunchAntigravityForUser"
$ruleName = "PCRemotePowerWeb"

foreach ($tn in @($taskName, $agyTaskName)) {
    $existing = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Stop-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $tn -Confirm:$false
        Write-Host "[제거 완료] '$tn' 작업을 삭제했습니다." -ForegroundColor Green
    }
}

$rules = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
if ($null -ne $rules) {
    $rules | Remove-NetFirewallRule
    Write-Host "[제거 완료] '$ruleName' 방화벽 규칙을 삭제했습니다." -ForegroundColor Green
}
