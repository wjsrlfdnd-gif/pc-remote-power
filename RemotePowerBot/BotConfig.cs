using System.Text.Json;

namespace RemotePowerBot;

/// <summary>
/// 디스코드 원격 전원 제어 봇 설정 모델입니다.
/// </summary>
public sealed class BotConfig
{
    public string BotToken { get; set; } = string.Empty;
    public ulong NotifyChannelId { get; set; }
    public List<ulong> AllowedUserIds { get; set; } = new();
    public int ShutdownDelaySeconds { get; set; } = 10;
    public bool SendBootNotification { get; set; } = true;
    public string PcDisplayName { get; set; } = Environment.MachineName;

    public static string ResolveConfigPath()
    {
        var candidates = new[]
        {
            Path.Combine(AppContext.BaseDirectory, "config.json"),
            Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "config.json")),
            Path.Combine(Directory.GetCurrentDirectory(), "config.json")
        };

        foreach (var candidate in candidates)
        {
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        // 기본 저장 위치는 프로젝트 루트(실행 폴더 상위)
        return Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "config.json"));
    }

    public static BotConfig Load(string path)
    {
        if (!File.Exists(path))
        {
            throw new FileNotFoundException(
                $"설정 파일을 찾을 수 없습니다: {path}\nconfig.example.json을 참고하거나 scripts\\2-setup-discord-bot.ps1을 실행해 config.json을 생성하세요.");
        }

        var json = File.ReadAllText(path);
        var options = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            ReadCommentHandling = JsonCommentHandling.Skip,
            AllowTrailingCommas = true
        };

        var config = JsonSerializer.Deserialize<BotConfig>(json, options)
            ?? throw new InvalidOperationException("config.json 형식을 해석할 수 없습니다.");

        if (string.IsNullOrWhiteSpace(config.PcDisplayName))
        {
            config.PcDisplayName = Environment.MachineName;
        }

        config.ShutdownDelaySeconds = Math.Clamp(config.ShutdownDelaySeconds, 0, 3600);
        return config;
    }

    public (bool IsValid, string ErrorMessage) Validate()
    {
        if (string.IsNullOrWhiteSpace(BotToken) ||
            BotToken.Contains("YOUR_DISCORD_BOT_TOKEN", StringComparison.OrdinalIgnoreCase))
        {
            return (false, "BotToken이 설정되지 않았습니다. Discord Developer Portal에서 발급받은 봇 토큰을 입력하세요.");
        }

        if (NotifyChannelId == 0)
        {
            return (false, "NotifyChannelId가 0입니다. 알림과 제어 패널을 받을 디스코드 채널 ID를 입력하세요.");
        }

        if (AllowedUserIds is null || AllowedUserIds.Count == 0 || AllowedUserIds.All(id => id == 0))
        {
            return (false, "AllowedUserIds가 비어 있습니다. 보안을 위해 명령을 허용할 본인 디스코드 사용자 ID를 최소 1개 등록해야 합니다.");
        }

        return (true, string.Empty);
    }
}
