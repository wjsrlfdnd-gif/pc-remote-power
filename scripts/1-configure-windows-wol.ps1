<#
.SYNOPSIS
    Windows Wake-on-LAN(WoL) 및 내장 유선 랜카드 설정을 일괄 적용합니다.
    반드시 관리자 권한으로 실행되어야 합니다(미승격 시 자동으로 UAC 승격을 요청합니다).
#>
param(
    [string]$LogFile = ""
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Write-LogLine {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Write-Host $line
    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        $dir = Split-Path -Parent $LogFile
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    Write-Host "관리자 권한이 필요하여 UAC 승격 창을 띄웁니다..."
    if ([string]::IsNullOrWhiteSpace($LogFile)) {
        $LogFile = Join-Path (Split-Path -Parent $PSScriptRoot) "logs\wol-setup.log"
    }
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -LogFile `"$LogFile`""
    try {
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs -Wait -PassThru
        if (Test-Path $LogFile) {
            Write-Host ""
            Get-Content -Path $LogFile -Encoding UTF8 | Select-Object -Last 30 | ForEach-Object { Write-Host $_ }
        }
        exit $proc.ExitCode
    }
    catch {
        Write-Host "[오류] 관리자 권한 승격이 취소되었거나 실패했습니다: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

Write-LogLine "=== Windows WoL 및 전원 설정 시작 ==="

# 1. 비활성화(Error) 상태의 유선 PCIe 랜카드 자동 활성화 시도
$disabledNics = Get-PnpDevice | Where-Object {
    $_.Class -eq 'Net' -and
    $_.InstanceId -like 'PCI\*' -and
    $_.FriendlyName -match 'Ethernet|GbE|Controller|Family' -and
    $_.FriendlyName -notmatch 'Wi-Fi|Wireless|Bluetooth' -and
    $_.Status -ne 'OK'
}

foreach ($nic in $disabledNics) {
    Write-LogLine "비활성 유선 랜 감지됨: $($nic.FriendlyName) (상태: $($nic.Status))"
    try {
        Enable-PnpDevice -InstanceId $nic.InstanceId -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 2
        $after = Get-PnpDevice -InstanceId $nic.InstanceId
        Write-LogLine "  -> 활성화 완료: $($after.Status)"
    }
    catch {
        Write-LogLine "  -> [경고] 활성화 오류: $($_.Exception.Message)"
    }
}

# 2. 물리 유선 이더넷 어댑터에 WoL 속성 및 절전 해제 허용 설정
$ethAdapters = Get-NetAdapter | Where-Object {
    ($_.PhysicalMediaType -match '802\.3' -or $_.InterfaceDescription -match 'Ethernet|GbE|Realtek|Intel') -and
    $_.InterfaceDescription -notmatch 'Bluetooth|Virtual|Wi-Fi|Wireless|Direct'
}

foreach ($adapter in $ethAdapters) {
    Write-LogLine "어댑터 설정 중: [$($adapter.Name)] $($adapter.InterfaceDescription) (Status=$($adapter.Status), MAC=$($adapter.MacAddress))"

    $advProps = Get-NetAdapterAdvancedProperty -Name $adapter.Name -ErrorAction SilentlyContinue
    foreach ($prop in $advProps) {
        if ($prop.DisplayName -match 'Wake on Magic Packet|매직 패킷 웨이크|Wake from S0ix on Magic Packet|Wake on Pattern Match|패턴 일치 웨이크') {
            $targetValue = $null
            if ($prop.ValidDisplayValues -contains 'Enabled') {
                $targetValue = 'Enabled'
            }
            elseif ($prop.ValidDisplayValues -contains '사용') {
                $targetValue = '사용'
            }
            elseif ($prop.ValidDisplayValues -contains '활성화함') {
                $targetValue = '활성화함'
            }

            if ($null -ne $targetValue -and $prop.DisplayValue -ne $targetValue) {
                try {
                    Set-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName $prop.DisplayName -DisplayValue $targetValue -ErrorAction Stop
                    Write-LogLine "  - 고급 속성 변경: $($prop.DisplayName) = $targetValue"
                }
                catch {
                    Write-LogLine "  - [참고] 고급 속성 변경 건너뜀($($prop.DisplayName)): $($_.Exception.Message)"
                }
            }
            else {
                Write-LogLine "  - 고급 속성 유지: $($prop.DisplayName) = $($prop.DisplayValue)"
            }
        }
    }

    try {
        Set-NetAdapterPowerManagement -Name $adapter.Name -WakeOnMagicPacket Enabled -WakeOnPattern Enabled -ErrorAction Stop
        Write-LogLine "  - NetAdapterPowerManagement(MagicPacket/Pattern) 활성화 완료"
    }
    catch {
        Write-LogLine "  - [참고] NetAdapterPowerManagement 미지원 또는 건너뜀: $($_.Exception.Message)"
    }

    try {
        $wakeOut = & powercfg.exe /deviceenablewake "$($adapter.InterfaceDescription)" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-LogLine "  - powercfg deviceenablewake 적용 완료"
        }
        else {
            Write-LogLine "  - [참고] powercfg deviceenablewake 응답(코드 $LASTEXITCODE): $($wakeOut -join ' ')"
        }
    }
    catch {
        Write-LogLine "  - [참고] powercfg 호출 오류: $($_.Exception.Message)"
    }
}

# 3. Windows 빠른 시작(Fast Startup) 해제 -> 완전 종료(S5) 후에도 WoL 유지
$powerRegPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
try {
    $beforeHiberboot = (Get-ItemProperty -Path $powerRegPath -Name 'HiberbootEnabled' -ErrorAction SilentlyContinue).HiberbootEnabled
    Set-ItemProperty -Path $powerRegPath -Name 'HiberbootEnabled' -Value 0 -Type DWord -ErrorAction Stop
    $afterHiberboot = (Get-ItemProperty -Path $powerRegPath -Name 'HiberbootEnabled').HiberbootEnabled
    Write-LogLine "빠른 시작 켜기(HiberbootEnabled) 변경: $beforeHiberboot -> $afterHiberboot (해제됨)"
}
catch {
    Write-LogLine "[오류] 빠른 시작 해제 실패: $($_.Exception.Message)"
}

# 4. 최종 검증 요약 출력
Write-LogLine "=== 설정 결과 검증 ==="
$wakeArmed = & powercfg.exe /devicequery wake_armed
Write-LogLine "현재 절전 해제 가능 장치(wake_armed):"
foreach ($w in $wakeArmed) {
    if (-not [string]::IsNullOrWhiteSpace($w)) {
        Write-LogLine "  * $w"
    }
}

Write-LogLine "어댑터 및 MAC 주소 요약 (공유기/중계기 WoL 등록용):"
foreach ($a in $ethAdapters) {
    $ip = (Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty IPv4Address) -join ','
    if ([string]::IsNullOrWhiteSpace($ip)) { $ip = '-' }
    Write-LogLine "  * [$($a.Name)] $($a.InterfaceDescription) | Status=$($a.Status) | MAC=$($a.MacAddress) | IP=$ip"
}

Write-LogLine "=== Windows WoL 설정 완료 ==="
