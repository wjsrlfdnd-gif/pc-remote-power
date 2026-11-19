using System.Text;
using PowerCore;

namespace RemotePowerWeb;

/// <summary>
/// 모바일 원클릭 PWA 웹 UI 및 REST API 서버 진입점입니다.
/// </summary>
public static class Program
{
    private static readonly object LogLock = new();
    private static string _logPath = string.Empty;

    public static async Task<int> Main(string[] args)
    {
        Console.OutputEncoding = Encoding.UTF8;
        _logPath = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "logs", "web.log"));

        if (args.Contains("--test-status", StringComparer.OrdinalIgnoreCase))
        {
            var status = PowerController.GetSystemStatus();
            Console.WriteLine($"PC: {status.MachineName} | Uptime: {status.Uptime} | Adapters: {status.Adapters.Count}");
            return 0;
        }

        var configPath = WebConfig.ResolveConfigPath();
        WebConfig config;
        try
        {
            config = WebConfig.Load(configPath);
            var (isValid, err) = config.Validate();
            if (!isValid)
            {
                WriteLog($"[설정 오류] {err} (경로: {configPath})");
                return 2;
            }
        }
        catch (Exception ex)
        {
            WriteLog($"[시작 실패] {ex.Message}");
            return 1;
        }

        if (args.Contains("--test-config", StringComparer.OrdinalIgnoreCase))
        {
            WriteLog($"[웹 설정 확인 완료] Port={config.ListenPort}, PC={config.PcDisplayName}, DuckDNS={(string.IsNullOrWhiteSpace(config.DuckDnsDomain) ? "미사용" : config.DuckDnsDomain)}");
            return 0;
        }

        var builder = WebApplication.CreateBuilder(args);
        builder.WebHost.ConfigureKestrel(options =>
        {
            options.ListenAnyIP(config.ListenPort);
        });
        builder.Logging.ClearProviders();

        var guard = new TokenAuthGuard(config.ApiToken);
        builder.Services.AddSingleton(config);
        builder.Services.AddSingleton(guard);
        builder.Services.AddHostedService(_ => new DuckDnsUpdater(config, WriteLog));

        var app = builder.Build();

        // GitHub Pages 등 외부 HTTPS PWA에서 사설망/Tailscale 백엔드 API를 호출할 수 있도록 CORS, PNA 및 OPTIONS 프리플라이트 허용
        app.Use(async (context, next) =>
        {
            context.Response.Headers["Access-Control-Allow-Origin"] = "*";
            context.Response.Headers["Access-Control-Allow-Headers"] = "Content-Type, X-Auth-Token, Authorization";
            context.Response.Headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS";
            context.Response.Headers["Access-Control-Allow-Private-Network"] = "true";
            context.Response.Headers["Access-Control-Max-Age"] = "86400";

            if (HttpMethods.IsOptions(context.Request.Method))
            {
                context.Response.StatusCode = StatusCodes.Status204NoContent;
                return;
            }

            await next();
        });

        // /api/* (health 제외) 경로에 토큰 인증 적용
        app.Use(async (context, next) =>
        {
            var path = context.Request.Path.Value ?? string.Empty;
            if (path.StartsWith("/api/", StringComparison.OrdinalIgnoreCase) &&
                !path.Equals("/api/health", StringComparison.OrdinalIgnoreCase))
            {
                var (authorized, statusCode, errorMessage) = guard.Authorize(context);
                if (!authorized)
                {
                    WriteLog($"[인증 거부] IP={context.Connection.RemoteIpAddress}, Path={path}, Status={statusCode}");
                    context.Response.StatusCode = statusCode;
                    await context.Response.WriteAsJsonAsync(new { success = false, message = errorMessage });
                    return;
                }
            }

            await next();
        });

        app.MapGet("/", () => Results.Content(
            MobileUi.BuildHtml(config.PcDisplayName, config.ShutdownDelaySeconds),
            "text/html; charset=utf-8"));

        app.MapGet("/manifest.webmanifest", () => Results.Content(
            MobileUi.BuildManifest(config.PcDisplayName),
            "application/manifest+json; charset=utf-8"));

        app.MapGet("/sw.js", () => Results.Content(
            MobileUi.ServiceWorkerJs,
            "application/javascript; charset=utf-8"));

        app.MapGet("/icon-192.png", () =>
        {
            var bytes = MobileUi.ReadEmbeddedPng("icon-192.png");
            return bytes is not null ? Results.Bytes(bytes, "image/png") : Results.NotFound();
        });

        app.MapGet("/icon-512.png", () =>
        {
            var bytes = MobileUi.ReadEmbeddedPng("icon-512.png");
            return bytes is not null ? Results.Bytes(bytes, "image/png") : Results.NotFound();
        });

        app.MapGet("/api/health", () => Results.Ok(new { ok = true }));

        app.MapGet("/api/status", () =>
        {
            var status = PowerController.GetSystemStatus();
            var uptimeText = $"{(int)status.Uptime.TotalHours}시간 {status.Uptime.Minutes}분 {status.Uptime.Seconds}초";
            return Results.Ok(new
            {
                success = true,
                machineName = status.MachineName,
                displayName = config.PcDisplayName,
                uptimeSeconds = (long)status.Uptime.TotalSeconds,
                uptimeText,
                antigravityInstalled = PowerController.FindAntigravityExePath() is not null,
                antigravityRunning = PowerController.IsAntigravityRunning(),
                userSessionActive = PowerController.IsUserSessionActive(),
                adapters = status.Adapters
            });
        });

        app.MapGet("/api/relay-script", () =>
        {
            var relayPath = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "relay", "wol_relay.py"));
            if (!File.Exists(relayPath))
            {
                return Results.NotFound(new { success = false, message = "wol_relay.py 파일을 찾을 수 없습니다." });
            }

            return Results.Text(File.ReadAllText(relayPath, Encoding.UTF8), "text/x-python; charset=utf-8");
        });

        app.MapPost("/api/app/antigravity/start", async (HttpContext ctx) =>
        {
            var clientIp = ctx.Connection.RemoteIpAddress?.ToString() ?? "unknown";
            var res = await PowerController.StartAntigravityAsync();
            WriteLog($"[앱 실행 요청] IP={clientIp}, App=Antigravity, Success={res.Success}, Msg={res.Message}");
            return Results.Json(
                new
                {
                    success = res.Success,
                    alreadyRunning = res.AlreadyRunning,
                    needsLogin = res.NeedsLogin,
                    message = res.Message
                },
                statusCode: res.Success ? 200 : (res.NeedsLogin ? 409 : 500));
        });

        app.MapPost("/api/power/{action}", (string action, HttpContext ctx) =>
        {
            var clientIp = ctx.Connection.RemoteIpAddress?.ToString() ?? "unknown";
            var normalized = action.Trim().ToLowerInvariant();
            WriteLog($"[전원 요청] IP={clientIp}, Action={normalized}");

            switch (normalized)
            {
                case "shutdown":
                case "off":
                    var shutdownRes = PowerController.ScheduleShutdown(config.ShutdownDelaySeconds, "모바일 원클릭 제어로 PC를 종료합니다.");
                    return Results.Json(
                        new { success = shutdownRes.Success, message = shutdownRes.Message },
                        statusCode: shutdownRes.Success ? 200 : 409);

                case "reboot":
                case "restart":
                    var rebootRes = PowerController.ScheduleReboot(config.ShutdownDelaySeconds, "모바일 원클릭 제어로 PC를 다시 시작합니다.");
                    return Results.Json(
                        new { success = rebootRes.Success, message = rebootRes.Message },
                        statusCode: rebootRes.Success ? 200 : 409);

                case "cancel":
                    var cancelRes = PowerController.CancelScheduledPowerAction();
                    return Results.Ok(new { success = cancelRes.Success, message = cancelRes.Message });

                case "sleep":
                    // HTTP 응답이 폰에 먼저 도착한 뒤 절전 모드(S3) 진입
                    _ = Task.Run(async () =>
                    {
                        await Task.Delay(1500);
                        var res = PowerController.EnterSleep();
                        if (!res.Success)
                        {
                            WriteLog($"[절전 실패] {res.Message}");
                        }
                    });
                    return Results.Ok(new { success = true, message = "약 1.5초 후 PC가 절전 모드(S3)로 전환됩니다." });

                default:
                    return Results.BadRequest(new { success = false, message = $"지원하지 않는 동작입니다: {action}" });
            }
        });

        WriteLog($"RemotePowerWeb 시작: http://0.0.0.0:{config.ListenPort} (PC={config.PcDisplayName})");
        await app.RunAsync();
        return 0;
    }

    private static void WriteLog(string message)
    {
        var line = $"[{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss zzz}] {message}";
        Console.WriteLine(line);

        try
        {
            lock (LogLock)
            {
                var dir = Path.GetDirectoryName(_logPath);
                if (!string.IsNullOrEmpty(dir))
                {
                    Directory.CreateDirectory(dir);
                }

                if (File.Exists(_logPath) && new FileInfo(_logPath).Length > 2 * 1024 * 1024)
                {
                    File.Copy(_logPath, _logPath + ".old", overwrite: true);
                    File.WriteAllText(_logPath, string.Empty);
                }

                File.AppendAllText(_logPath, line + Environment.NewLine, Encoding.UTF8);
            }
        }
        catch
        {
            // 로그 오류 무시
        }
    }
}
