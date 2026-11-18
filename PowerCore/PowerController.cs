using System.Diagnostics;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace PowerCore;

/// <summary>
/// Windows 전원 제어(종료, 재부팅, 절전, 예약 취소), 시스템 상태 조회 및 Antigravity 실행을 담당합니다.
/// </summary>
public static class PowerController
{
    public const string AntigravityTaskName = "LaunchAntigravityForUser";

    private const uint TokenAdjustPrivileges = 0x0020;
    private const uint TokenQuery = 0x0008;
    private const uint SePrivilegeEnabled = 0x00000002;
    private const string SeShutdownName = "SeShutdownPrivilege";

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct Luid
    {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct TokenPrivileges
    {
        public uint PrivilegeCount;
        public Luid Luid;
        public uint Attributes;
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(
        IntPtr processHandle,
        uint desiredAccess,
        out IntPtr tokenHandle);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LookupPrivilegeValue(
        string? lpSystemName,
        string lpName,
        out Luid lpLuid);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool AdjustTokenPrivileges(
        IntPtr tokenHandle,
        bool disableAllPrivileges,
        ref TokenPrivileges newState,
        uint bufferLength,
        IntPtr previousState,
        IntPtr returnLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    [DllImport("powrprof.dll", SetLastError = true)]
    private static extern bool SetSuspendState(
        bool hibernate,
        bool forceCritical,
        bool disableWakeEvent);

    public sealed record PowerActionResult(bool Success, string Message);

    public sealed record AppLaunchResult(
        bool Success,
        string Message,
        bool AlreadyRunning = false,
        bool NeedsLogin = false);

    public sealed record AdapterInfo(
        string Name,
        string Description,
        string MacAddress,
        string IPv4,
        string SpeedText,
        bool IsUp);

    public sealed record SystemStatus(
        string MachineName,
        string OsDescription,
        TimeSpan Uptime,
        IReadOnlyList<AdapterInfo> Adapters);

    public static PowerActionResult ScheduleShutdown(int delaySeconds, string reason = "원격 제어로 PC를 종료합니다.")
    {
        var clampedDelay = Math.Clamp(delaySeconds, 0, 3600);
        var exitCode = RunSystemCommand("shutdown.exe", $"/s /t {clampedDelay} /f /c \"{reason}\"");

        return exitCode switch
        {
            0 => new PowerActionResult(true, $"{clampedDelay}초 후 PC가 종료됩니다. 실수했다면 '예약 취소'를 누르세요."),
            1190 => new PowerActionResult(false, "이미 예약된 종료 또는 재부팅 작업이 있습니다. 먼저 '예약 취소' 후 다시 시도하세요."),
            _ => new PowerActionResult(false, $"종료 명령 실행에 실패했습니다. (종료 코드: {exitCode})")
        };
    }

    public static PowerActionResult ScheduleReboot(int delaySeconds, string reason = "원격 제어로 PC를 다시 시작합니다.")
    {
        var clampedDelay = Math.Clamp(delaySeconds, 0, 3600);
        var exitCode = RunSystemCommand("shutdown.exe", $"/r /t {clampedDelay} /f /c \"{reason}\"");

        return exitCode switch
        {
            0 => new PowerActionResult(true, $"{clampedDelay}초 후 PC가 다시 시작됩니다. 실수했다면 '예약 취소'를 누르세요."),
            1190 => new PowerActionResult(false, "이미 예약된 종료 또는 재부팅 작업이 있습니다. 먼저 '예약 취소' 후 다시 시도하세요."),
            _ => new PowerActionResult(false, $"다시 시작 명령 실행에 실패했습니다. (종료 코드: {exitCode})")
        };
    }

    public static PowerActionResult CancelScheduledPowerAction()
    {
        var exitCode = RunSystemCommand("shutdown.exe", "/a");

        return exitCode switch
        {
            0 => new PowerActionResult(true, "예약된 종료/재부팅을 취소했습니다."),
            1116 => new PowerActionResult(false, "현재 진행 중인 종료 또는 재부팅 예약이 없습니다."),
            _ => new PowerActionResult(false, $"예약 취소 중 오류가 발생했습니다. (종료 코드: {exitCode})")
        };
    }

    public static PowerActionResult EnterSleep()
    {
        if (!EnableShutdownPrivilege(out var privilegeError))
        {
            return new PowerActionResult(false, $"절전 권한 활성화에 실패했습니다: {privilegeError}");
        }

        // Win32 API 직접 호출로 최대 절전 모드가 아닌 일반 절전 모드(S3)로 진입
        var result = SetSuspendState(hibernate: false, forceCritical: false, disableWakeEvent: false);
        if (!result)
        {
            var err = Marshal.GetLastWin32Error();
            return new PowerActionResult(false, $"절전 모드 진입에 실패했습니다. (Win32 오류 코드: {err})");
        }

        return new PowerActionResult(true, "절전 모드에서 복귀했습니다.");
    }

    public static bool IsUserSessionActive()
    {
        try
        {
            return Process.GetProcessesByName("explorer").Any(p => p.SessionId > 0);
        }
        catch
        {
            return false;
        }
    }

    public static bool IsAntigravityRunning()
    {
        try
        {
            return Process.GetProcessesByName("Antigravity").Any(p => p.SessionId > 0);
        }
        catch
        {
            return false;
        }
    }

    public static string? FindAntigravityExePath()
    {
        var localCandidate = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Programs", "antigravity", "Antigravity.exe");
        if (File.Exists(localCandidate))
        {
            return localCandidate;
        }

        try
        {
            var usersDir = Path.Combine(Path.GetPathRoot(Environment.SystemDirectory) ?? @"C:\", "Users");
            if (Directory.Exists(usersDir))
            {
                foreach (var userDir in Directory.GetDirectories(usersDir))
                {
                    var candidate = Path.Combine(userDir, "AppData", "Local", "Programs", "antigravity", "Antigravity.exe");
                    if (File.Exists(candidate))
                    {
                        return candidate;
                    }
                }
            }
        }
        catch
        {
            // 권한이 없는 사용자 폴더 무시
        }

        var programFilesCandidate = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            "Antigravity", "Antigravity.exe");
        return File.Exists(programFilesCandidate) ? programFilesCandidate : null;
    }

    public static async Task<AppLaunchResult> StartAntigravityAsync()
    {
        if (IsAntigravityRunning())
        {
            return new AppLaunchResult(true, "Antigravity 앱이 이미 실행 중입니다.", AlreadyRunning: true);
        }

        if (!IsUserSessionActive())
        {
            return new AppLaunchResult(
                false,
                "PC가 부팅된 후 아직 Windows 로그인이 되지 않았습니다. 먼저 Windows App으로 한 번 로그인해 주세요.",
                NeedsLogin: true);
        }

        var exitCode = RunSystemCommand("schtasks.exe", $"/run /tn \"{AntigravityTaskName}\"");
        if (exitCode != 0)
        {
            return new AppLaunchResult(
                false,
                $"실행 작업({AntigravityTaskName}) 호출에 실패했습니다(코드 {exitCode}). '3_웹_자동실행_방화벽_등록(관리자).bat'을 실행해 주세요.");
        }

        for (var i = 0; i < 10; i++)
        {
            await Task.Delay(500);
            if (IsAntigravityRunning())
            {
                return new AppLaunchResult(true, "Antigravity 앱을 실행했습니다. 잠시 후 Remote Control에 연결됩니다.");
            }
        }

        return new AppLaunchResult(true, "Antigravity 실행 요청을 보냈습니다. 몇 초 뒤 상태를 다시 확인해 주세요.");
    }

    public static SystemStatus GetSystemStatus()
    {
        var adapters = NetworkInterface.GetAllNetworkInterfaces()
            .Where(nic =>
                nic.NetworkInterfaceType != NetworkInterfaceType.Loopback &&
                nic.NetworkInterfaceType != NetworkInterfaceType.Tunnel &&
                nic.GetPhysicalAddress().GetAddressBytes().Length == 6 &&
                !Regex.IsMatch(nic.Description, @"-\d{4}$") &&
                !nic.Description.Contains("Wi-Fi Direct", StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(nic => nic.OperationalStatus == OperationalStatus.Up)
            .ThenBy(nic => nic.Name, StringComparer.OrdinalIgnoreCase)
            .Select(nic =>
            {
                var macBytes = nic.GetPhysicalAddress().GetAddressBytes();
                var mac = string.Join("-", macBytes.Select(b => b.ToString("X2")));

                var ipv4List = nic.GetIPProperties().UnicastAddresses
                    .Where(addr => addr.Address.AddressFamily == AddressFamily.InterNetwork)
                    .Select(addr => addr.Address.ToString())
                    .ToList();

                var ipv4 = ipv4List.Count > 0 ? string.Join(", ", ipv4List) : "-";
                var speedText = FormatSpeed(nic.Speed);

                return new AdapterInfo(
                    nic.Name,
                    nic.Description,
                    mac,
                    ipv4,
                    speedText,
                    nic.OperationalStatus == OperationalStatus.Up);
            })
            .ToList();

        return new SystemStatus(
            Environment.MachineName,
            RuntimeInformation.OSDescription,
            TimeSpan.FromMilliseconds(Environment.TickCount64),
            adapters);
    }

    private static string FormatSpeed(long bitsPerSecond)
    {
        if (bitsPerSecond <= 0)
        {
            return "-";
        }

        if (bitsPerSecond >= 1_000_000_000)
        {
            return $"{bitsPerSecond / 1_000_000_000.0:0.#} Gbps";
        }

        if (bitsPerSecond >= 1_000_000)
        {
            return $"{bitsPerSecond / 1_000_000.0:0.#} Mbps";
        }

        return $"{bitsPerSecond} bps";
    }

    private static int RunSystemCommand(string exeName, string arguments)
    {
        var psi = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), exeName),
            Arguments = arguments,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };

        using var process = Process.Start(psi)
            ?? throw new InvalidOperationException($"{exeName} 프로세스를 시작할 수 없습니다.");

        process.WaitForExit(5000);
        return process.ExitCode;
    }

    private static bool EnableShutdownPrivilege(out string error)
    {
        error = string.Empty;
        var tokenHandle = IntPtr.Zero;

        try
        {
            using var currentProcess = Process.GetCurrentProcess();
            if (!OpenProcessToken(currentProcess.Handle, TokenAdjustPrivileges | TokenQuery, out tokenHandle))
            {
                error = $"OpenProcessToken 오류({Marshal.GetLastWin32Error()})";
                return false;
            }

            if (!LookupPrivilegeValue(null, SeShutdownName, out var luid))
            {
                error = $"LookupPrivilegeValue 오류({Marshal.GetLastWin32Error()})";
                return false;
            }

            var privileges = new TokenPrivileges
            {
                PrivilegeCount = 1,
                Luid = luid,
                Attributes = SePrivilegeEnabled
            };

            if (!AdjustTokenPrivileges(tokenHandle, false, ref privileges, 0, IntPtr.Zero, IntPtr.Zero))
            {
                error = $"AdjustTokenPrivileges 오류({Marshal.GetLastWin32Error()})";
                return false;
            }

            var lastError = Marshal.GetLastWin32Error();
            if (lastError != 0)
            {
                error = $"권한 부여 거부({lastError}) - 관리자/SYSTEM 권한 필요";
                return false;
            }

            return true;
        }
        finally
        {
            if (tokenHandle != IntPtr.Zero)
            {
                CloseHandle(tokenHandle);
            }
        }
    }
}
