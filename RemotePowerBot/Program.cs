using System.Text;
using Discord;
using Discord.WebSocket;
using PowerCore;

namespace RemotePowerBot;

/// <summary>
/// Discord 봇 진입점: 슬래시 명령어, 인라인 버튼 패널, 부팅/절전 복귀 알림을 처리합니다.
/// </summary>
public static class Program
{
    private const string IdAskShutdown = "power:ask_shutdown";
    private const string IdAskSleep = "power:ask_sleep";
    private const string IdAskReboot = "power:ask_reboot";
    private const string IdConfirmShutdown = "power:confirm_shutdown";
    private const string IdConfirmSleep = "power:confirm_sleep";
    private const string IdConfirmReboot = "power:confirm_reboot";
    private const string IdCancelSchedule = "power:cancel_schedule";
    private const string IdStatus = "power:status";
    private const string IdDismiss = "power:dismiss";

    private static BotConfig _config = null!;
    private static DiscordSocketClient _client = null!;
    private static int _bootNotificationSent;
    private static int _pendingResumeNotification;
    private static long _lastResumeSentUtcTicks;
    private static readonly object LogLock = new();
    private static string _logPath = string.Empty;

    public static async Task<int> Main(string[] args)
    {
        Console.OutputEncoding = Encoding.UTF8;
        _logPath = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "logs", "bot.log"));

        if (args.Contains("--test-status", StringComparer.OrdinalIgnoreCase))
        {
            var status = PowerController.GetSystemStatus();
            Console.WriteLine($"PC: {status.MachineName} | Uptime: {status.Uptime} | Adapters: {status.Adapters.Count}");
            foreach (var a in status.Adapters)
            {
                Console.WriteLine($" - {a.Name} [{(a.IsUp ? "Up" : "Down")}] MAC={a.MacAddress} IP={a.IPv4} ({a.Description})");
            }
            return 0;
        }

        var configPath = BotConfig.ResolveConfigPath();
        try
        {
            _config = BotConfig.Load(configPath);
            var (isValid, validationError) = _config.Validate();
            if (!isValid)
            {
                WriteLog($"[설정 오류] {validationError} (경로: {configPath})");
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
            WriteLog($"[설정 확인 완료] PC={_config.PcDisplayName}, Channel={_config.NotifyChannelId}, AllowedUsers={string.Join(",", _config.AllowedUserIds)}");
            return 0;
        }

        using var cts = new CancellationTokenSource();
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true;
            cts.Cancel();
        };

        // Privileged Intent 없이 동작하도록 Guilds 및 DirectMessages만 사용
        var socketConfig = new DiscordSocketConfig
        {
            GatewayIntents = GatewayIntents.Guilds | GatewayIntents.DirectMessages,
            LogLevel = LogSeverity.Info,
            ConnectionTimeout = 15000
        };

        _client = new DiscordSocketClient(socketConfig);
        _client.Log += OnLogAsync;
        _client.Ready += OnReadyAsync;
        _client.Connected += OnConnectedAsync;
        _client.SlashCommandExecuted += OnSlashCommandExecutedAsync;
        _client.ButtonExecuted += OnButtonExecutedAsync;

        // 부팅 직후 네트워크/DHCP 초기화 완료까지 재시도하며 연결
        while (!cts.IsCancellationRequested)
        {
            try
            {
                WriteLog("Discord 게이트웨이 연결을 시도합니다...");
                await _client.LoginAsync(TokenType.Bot, _config.BotToken);
                await _client.StartAsync();
                break;
            }
            catch (Exception ex)
            {
                WriteLog($"[연결 재시도 대기] {ex.Message}");
                await SafeDelayAsync(TimeSpan.FromSeconds(5), cts.Token);
            }
        }

        if (!cts.IsCancellationRequested)
        {
            _ = MonitorSleepResumeAsync(cts.Token);
            try
            {
                await Task.Delay(Timeout.Infinite, cts.Token);
            }
            catch (OperationCanceledException)
            {
                // 정상 종료
            }
        }

        try
        {
            await _client.StopAsync();
            await _client.LogoutAsync();
        }
        catch
        {
            // 종료 중 예외 무시
        }

        WriteLog("Discord 원격 전원 봇이 종료되었습니다.");
        return 0;
    }

    private static Task OnLogAsync(LogMessage message)
    {
        WriteLog($"[Discord/{message.Severity}] {message.Source}: {message.Message} {message.Exception?.Message}".Trim());
        return Task.CompletedTask;
    }

    private static Task OnConnectedAsync()
    {
        if (Volatile.Read(ref _pendingResumeNotification) == 1 && Volatile.Read(ref _bootNotificationSent) == 1)
        {
            _ = Task.Run(async () =>
            {
                await Task.Delay(2500);
                if (Interlocked.Exchange(ref _pendingResumeNotification, 0) == 1)
                {
                    await TrySendResumeNotificationAsync();
                }
            });
        }

        return Task.CompletedTask;
    }

    private static async Task OnReadyAsync()
    {
        WriteLog($"봇 로그인 완료: {_client.CurrentUser?.Username} ({_client.CurrentUser?.Id})");

        await RegisterSlashCommandsAsync();

        if (Interlocked.Exchange(ref _bootNotificationSent, 1) == 0)
        {
            if (_config.SendBootNotification)
            {
                await SendPanelNotificationAsync(
                    "🟢 PC가 켜졌습니다",
                    $"**{_config.PcDisplayName}** 부팅 및 원격 제어 준비가 완료되었습니다.",
                    Color.Green);
            }
        }
        else if (Interlocked.Exchange(ref _pendingResumeNotification, 0) == 1)
        {
            await TrySendResumeNotificationAsync();
        }
    }

    private static async Task RegisterSlashCommandsAsync()
    {
        var commands = new ApplicationCommandProperties[]
        {
            new SlashCommandBuilder()
                .WithName("power")
                .WithDescription("PC 원격 전원 제어 패널을 표시합니다.")
                .Build(),
            new SlashCommandBuilder()
                .WithName("status")
                .WithDescription("PC 가동 시간 및 네트워크(IP/MAC) 상태를 확인합니다.")
                .Build(),
            new SlashCommandBuilder()
                .WithName("shutdown")
                .WithDescription("PC 종료 확인 버튼을 표시합니다.")
                .Build(),
            new SlashCommandBuilder()
                .WithName("sleep")
                .WithDescription("PC 절전 모드 확인 버튼을 표시합니다.")
                .Build(),
            new SlashCommandBuilder()
                .WithName("reboot")
                .WithDescription("PC 다시 시작 확인 버튼을 표시합니다.")
                .Build(),
            new SlashCommandBuilder()
                .WithName("cancel")
                .WithDescription("예약된 PC 종료/재부팅을 취소합니다.")
                .Build()
        };

        foreach (var guild in _client.Guilds)
        {
            try
            {
                await guild.BulkOverwriteApplicationCommandAsync(commands);
                WriteLog($"서버 '{guild.Name}' ({guild.Id})에 슬래시 명령어를 등록했습니다.");
            }
            catch (Exception ex)
            {
                WriteLog($"[명령어 등록 오류] {guild.Name}: {ex.Message}");
            }
        }
    }

    private static async Task OnSlashCommandExecutedAsync(SocketSlashCommand command)
    {
        if (!IsAuthorized(command.User.Id))
        {
            WriteLog($"[접근 거부] SlashCommand={command.CommandName}, User={command.User.Username} ({command.User.Id})");
            await command.RespondAsync("⛔ 허용되지 않은 사용자입니다.", ephemeral: true);
            return;
        }

        switch (command.CommandName)
        {
            case "power":
                await command.RespondAsync(
                    embed: BuildStatusEmbed($"🖥️ {_config.PcDisplayName} 원격 전원 제어", "아래 버튼으로 전원을 제어할 수 있습니다.", Color.Blue),
                    components: BuildControlPanel());
                break;

            case "status":
                await command.RespondAsync(
                    embed: BuildStatusEmbed($"📊 {_config.PcDisplayName} 현재 상태", "실시간 시스템 및 네트워크 정보입니다.", Color.Teal),
                    components: BuildControlPanel(),
                    ephemeral: true);
                break;

            case "shutdown":
                await SendConfirmPromptAsync(command, "⏻ 정말 PC를 종료할까요?", $"{_config.ShutdownDelaySeconds}초 카운트다운 후 종료됩니다.", IdConfirmShutdown, "예, 종료합니다", ButtonStyle.Danger);
                break;

            case "sleep":
                await SendConfirmPromptAsync(command, "🌙 PC를 절전 모드(S3)로 전환할까요?", "공유기 Wake-on-LAN으로 다시 켤 수 있습니다.", IdConfirmSleep, "예, 절전 모드로 전환", ButtonStyle.Primary);
                break;

            case "reboot":
                await SendConfirmPromptAsync(command, "🔄 정말 PC를 다시 시작할까요?", $"{_config.ShutdownDelaySeconds}초 카운트다운 후 재부팅됩니다.", IdConfirmReboot, "예, 다시 시작합니다", ButtonStyle.Danger);
                break;

            case "cancel":
                var cancelResult = PowerController.CancelScheduledPowerAction();
                await command.RespondAsync(cancelResult.Success ? $"✅ {cancelResult.Message}" : $"ℹ️ {cancelResult.Message}");
                break;

            default:
                await command.RespondAsync("알 수 없는 명령어입니다.", ephemeral: true);
                break;
        }
    }

    private static async Task OnButtonExecutedAsync(SocketMessageComponent component)
    {
        if (!IsAuthorized(component.User.Id))
        {
            WriteLog($"[접근 거부] Button={component.Data.CustomId}, User={component.User.Username} ({component.User.Id})");
            await component.RespondAsync("⛔ 허용되지 않은 사용자입니다.", ephemeral: true);
            return;
        }

        switch (component.Data.CustomId)
        {
            case IdAskShutdown:
                await SendConfirmPromptAsync(component, "⏻ 정말 PC를 종료할까요?", $"{_config.ShutdownDelaySeconds}초 카운트다운 후 종료됩니다.", IdConfirmShutdown, "예, 종료합니다", ButtonStyle.Danger);
                break;

            case IdAskSleep:
                await SendConfirmPromptAsync(component, "🌙 PC를 절전 모드(S3)로 전환할까요?", "확인 후 약 2초 뒤에 절전 모드로 들어갑니다.", IdConfirmSleep, "예, 절전 모드로 전환", ButtonStyle.Primary);
                break;

            case IdAskReboot:
                await SendConfirmPromptAsync(component, "🔄 정말 PC를 다시 시작할까요?", $"{_config.ShutdownDelaySeconds}초 카운트다운 후 재부팅됩니다.", IdConfirmReboot, "예, 다시 시작합니다", ButtonStyle.Danger);
                break;

            case IdConfirmShutdown:
                await ExecuteScheduledActionAsync(component, isReboot: false);
                break;

            case IdConfirmReboot:
                await ExecuteScheduledActionAsync(component, isReboot: true);
                break;

            case IdConfirmSleep:
                await ExecuteSleepAsync(component);
                break;

            case IdStatus:
                await component.RespondAsync(
                    embed: BuildStatusEmbed($"📊 {_config.PcDisplayName} 현재 상태", "실시간 시스템 및 네트워크 정보입니다.", Color.Teal),
                    components: BuildControlPanel(),
                    ephemeral: true);
                break;

            case IdCancelSchedule:
                var cancelResult = PowerController.CancelScheduledPowerAction();
                await component.RespondAsync(cancelResult.Success ? $"✅ {cancelResult.Message}" : $"ℹ️ {cancelResult.Message}");
                break;

            case IdDismiss:
                await component.UpdateAsync(props =>
                {
                    props.Content = "취소되었습니다.";
                    props.Embed = null;
                    props.Components = new ComponentBuilder().Build();
                });
                break;

            default:
                await component.RespondAsync("알 수 없는 버튼 동작입니다.", ephemeral: true);
                break;
        }
    }

    private static async Task ExecuteScheduledActionAsync(SocketMessageComponent component, bool isReboot)
    {
        var result = isReboot
            ? PowerController.ScheduleReboot(_config.ShutdownDelaySeconds)
            : PowerController.ScheduleShutdown(_config.ShutdownDelaySeconds);

        var title = isReboot ? "🔄 다시 시작 예약됨" : "⏻ 시스템 종료 예약됨";
        WriteLog($"[전원 동작] User={component.User.Id}, Action={(isReboot ? "Reboot" : "Shutdown")}, Success={result.Success}, Msg={result.Message}");

        await component.UpdateAsync(props =>
        {
            props.Content = result.Success ? $"✅ {title}: {result.Message}" : $"⚠️ {result.Message}";
            props.Embed = null;
            props.Components = new ComponentBuilder().Build();
        });

        if (result.Success)
        {
            var cancelPanel = new ComponentBuilder()
                .WithButton("❌ 예약 취소", IdCancelSchedule, ButtonStyle.Secondary)
                .Build();

            await component.Channel.SendMessageAsync(
                $"⚠️ **{component.User.Mention}** 요청으로 **{title}** — {result.Message}",
                components: cancelPanel);
        }
    }

    private static async Task ExecuteSleepAsync(SocketMessageComponent component)
    {
        WriteLog($"[전원 동작] User={component.User.Id}, Action=Sleep");

        await component.UpdateAsync(props =>
        {
            props.Content = "🌙 절전 모드로 전환하는 중입니다...";
            props.Embed = null;
            props.Components = new ComponentBuilder().Build();
        });

        await component.Channel.SendMessageAsync($"🌙 **{component.User.Mention}** 요청으로 **{_config.PcDisplayName}**가 절전 모드(S3)로 전환됩니다.");

        // Discord 응답 패킷 전송이 끝날 때까지 잠시 대기한 뒤 절전 실행
        _ = Task.Run(async () =>
        {
            await Task.Delay(2000);
            var result = PowerController.EnterSleep();
            if (!result.Success)
            {
                WriteLog($"[절전 실패] {result.Message}");
                await SendTextNotificationAsync($"⚠️ {result.Message}");
                return;
            }

            // SetSuspendState가 반환된 시점이 절전 복귀 시점
            WriteLog("[절전 복귀] SetSuspendState 호출이 복귀를 감지했습니다.");
            await Task.Delay(4000);
            if (_client.ConnectionState == ConnectionState.Connected)
            {
                await TrySendResumeNotificationAsync();
            }
            else
            {
                Interlocked.Exchange(ref _pendingResumeNotification, 1);
            }
        });
    }

    private static async Task MonitorSleepResumeAsync(CancellationToken token)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(5));
        var lastTick = DateTimeOffset.UtcNow;

        while (await timer.WaitForNextTickAsync(token))
        {
            var now = DateTimeOffset.UtcNow;
            var elapsed = now - lastTick;
            lastTick = now;

            // 외부 요인(시작 메뉴 등)으로 절전 모드 진입 후 복귀했을 때도 감지
            if (elapsed > TimeSpan.FromSeconds(25))
            {
                WriteLog($"[절전 복귀 감지] 시간 점프={elapsed.TotalSeconds:0.1}초");

                if (_client.ConnectionState == ConnectionState.Connected)
                {
                    await Task.Delay(3000, token);
                    await TrySendResumeNotificationAsync();
                }
                else
                {
                    Interlocked.Exchange(ref _pendingResumeNotification, 1);
                }
            }
        }
    }

    private static async Task TrySendResumeNotificationAsync()
    {
        var nowTicks = DateTimeOffset.UtcNow.UtcTicks;
        var prevTicks = Interlocked.Read(ref _lastResumeSentUtcTicks);
        if (prevTicks != 0 && TimeSpan.FromTicks(nowTicks - prevTicks) < TimeSpan.FromSeconds(15))
        {
            return;
        }

        if (Interlocked.CompareExchange(ref _lastResumeSentUtcTicks, nowTicks, prevTicks) != prevTicks)
        {
            return;
        }

        await SendPanelNotificationAsync(
            "🟢 절전 모드에서 복귀했습니다",
            $"**{_config.PcDisplayName}**가 절전 모드에서 깨어나 네트워크에 연결되었습니다.",
            Color.Green);
    }

    private static async Task SendPanelNotificationAsync(string title, string description, Color color)
    {
        try
        {
            var channel = await ResolveNotifyChannelAsync();
            if (channel is null)
            {
                WriteLog($"[알림 실패] 채널({_config.NotifyChannelId})을 찾을 수 없습니다. 봇이 해당 서버/채널에 초대되어 있고 보기/전송 권한이 있는지 확인하세요.");
                return;
            }

            await channel.SendMessageAsync(
                embed: BuildStatusEmbed(title, description, color),
                components: BuildControlPanel());
        }
        catch (Exception ex)
        {
            WriteLog($"[알림 전송 오류] {ex.Message}");
        }
    }

    private static async Task SendTextNotificationAsync(string text)
    {
        try
        {
            var channel = await ResolveNotifyChannelAsync();
            if (channel is not null)
            {
                await channel.SendMessageAsync(text);
            }
        }
        catch (Exception ex)
        {
            WriteLog($"[텍스트 알림 오류] {ex.Message}");
        }
    }

    private static async Task<IMessageChannel?> ResolveNotifyChannelAsync()
    {
        if (_client.GetChannel(_config.NotifyChannelId) is IMessageChannel cached)
        {
            return cached;
        }

        return await _client.Rest.GetChannelAsync(_config.NotifyChannelId) as IMessageChannel;
    }

    private static async Task SendConfirmPromptAsync(
        IDiscordInteraction interaction,
        string title,
        string description,
        string confirmId,
        string confirmLabel,
        ButtonStyle confirmStyle)
    {
        var embed = new EmbedBuilder()
            .WithTitle(title)
            .WithDescription(description)
            .WithColor(Color.Orange)
            .Build();

        var buttons = new ComponentBuilder()
            .WithButton(confirmLabel, confirmId, confirmStyle)
            .WithButton("취소", IdDismiss, ButtonStyle.Secondary)
            .Build();

        await interaction.RespondAsync(embed: embed, components: buttons, ephemeral: true);
    }

    private static MessageComponent BuildControlPanel()
    {
        return new ComponentBuilder()
            .WithButton("⏻ 전원 끄기", IdAskShutdown, ButtonStyle.Danger, row: 0)
            .WithButton("🌙 절전 모드", IdAskSleep, ButtonStyle.Primary, row: 0)
            .WithButton("🔄 다시 시작", IdAskReboot, ButtonStyle.Secondary, row: 0)
            .WithButton("📊 상태 확인", IdStatus, ButtonStyle.Success, row: 1)
            .WithButton("❌ 예약 취소", IdCancelSchedule, ButtonStyle.Secondary, row: 1)
            .Build();
    }

    private static Embed BuildStatusEmbed(string title, string description, Color color)
    {
        var status = PowerController.GetSystemStatus();
        var uptimeText = $"{(int)status.Uptime.TotalHours}시간 {status.Uptime.Minutes}분 {status.Uptime.Seconds}초";

        var activeLines = status.Adapters
            .Where(a => a.IsUp)
            .Select(a => $"• **{a.Name}** (`{a.IPv4}`, `{a.SpeedText}`)\n  MAC: `{a.MacAddress}` ({a.Description})")
            .ToList();

        var networkSummary = activeLines.Count > 0
            ? string.Join("\n", activeLines)
            : "활성 네트워크 어댑터가 없습니다.";

        return new EmbedBuilder()
            .WithTitle(title)
            .WithDescription(description)
            .WithColor(color)
            .AddField("PC 이름", $"`{status.MachineName}`", inline: true)
            .AddField("가동 시간", $"`{uptimeText}`", inline: true)
            .AddField("네트워크 (WoL MAC 참고)", networkSummary, inline: false)
            .WithFooter("전원 켜기(ON)는 LG U+ 공유기 Wake-on-LAN 메뉴를 사용하세요.")
            .WithCurrentTimestamp()
            .Build();
    }

    private static bool IsAuthorized(ulong userId) => _config.AllowedUserIds.Contains(userId);

    private static async Task SafeDelayAsync(TimeSpan delay, CancellationToken token)
    {
        try
        {
            await Task.Delay(delay, token);
        }
        catch (OperationCanceledException)
        {
            // 무시
        }
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

                // 로그 파일이 2MB를 넘으면 백업 1개만 유지하고 회전
                if (File.Exists(_logPath) && new FileInfo(_logPath).Length > 2 * 1024 * 1024)
                {
                    var backup = _logPath + ".old";
                    File.Copy(_logPath, backup, overwrite: true);
                    File.WriteAllText(_logPath, string.Empty);
                }

                File.AppendAllText(_logPath, line + Environment.NewLine, Encoding.UTF8);
            }
        }
        catch
        {
            // 로그 기록 실패가 봇 동작을 막지 않도록 처리
        }
    }
}
