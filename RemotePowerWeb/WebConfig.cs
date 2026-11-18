using System.Text.Json;

namespace RemotePowerWeb;

/// <summary>
/// 모바일 원클릭 웹 제어 서버 설정 모델입니다.
/// </summary>
public sealed class WebConfig
{
    public int ListenPort { get; set; } = 18080;
    public string ApiToken { get; set; } = string.Empty;
    public string PcDisplayName { get; set; } = Environment.MachineName;
    public int ShutdownDelaySeconds { get; set; } = 5;
    public string DuckDnsDomain { get; set; } = string.Empty;
    public string DuckDnsToken { get; set; } = string.Empty;

    public static string ResolveConfigPath()
    {
        var candidates = new[]
        {
            Path.Combine(AppContext.BaseDirectory, "web-config.json"),
            Path.Combine(Directory.GetCurrentDirectory(), "web-config.json"),
            Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "web-config.json"))
        };

        foreach (var candidate in candidates)
        {
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "web-config.json"));
    }

    public static WebConfig Load(string path)
    {
        if (!File.Exists(path))
        {
            throw new FileNotFoundException(
                $"웹 설정 파일을 찾을 수 없습니다: {path}\nscripts\\setup-web-control.ps1을 실행해 web-config.json을 생성하세요.");
        }

        var json = File.ReadAllText(path);
        var options = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            ReadCommentHandling = JsonCommentHandling.Skip,
            AllowTrailingCommas = true
        };

        var config = JsonSerializer.Deserialize<WebConfig>(json, options)
            ?? throw new InvalidOperationException("web-config.json 형식을 해석할 수 없습니다.");

        if (string.IsNullOrWhiteSpace(config.PcDisplayName))
        {
            config.PcDisplayName = Environment.MachineName;
        }

        config.ListenPort = Math.Clamp(config.ListenPort, 1024, 65535);
        config.ShutdownDelaySeconds = Math.Clamp(config.ShutdownDelaySeconds, 0, 3600);
        return config;
    }

    public (bool IsValid, string ErrorMessage) Validate()
    {
        if (string.IsNullOrWhiteSpace(ApiToken) ||
            ApiToken.Length < 16 ||
            ApiToken.Contains("CHANGE_ME", StringComparison.OrdinalIgnoreCase))
        {
            return (false, "ApiToken이 비어 있거나 너무 짧습니다. 16자 이상의 무작위 토큰을 설정하세요.");
        }

        return (true, string.Empty);
    }
}
