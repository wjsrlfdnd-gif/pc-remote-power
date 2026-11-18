namespace RemotePowerWeb;

/// <summary>
/// DuckDNS 도메인이 설정된 경우 주기적으로 현재 공인 IP를 갱신합니다.
/// </summary>
public sealed class DuckDnsUpdater : BackgroundService
{
    private readonly WebConfig _config;
    private readonly Action<string> _log;
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(10) };

    public DuckDnsUpdater(WebConfig config, Action<string> log)
    {
        _config = config;
        _log = log;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (string.IsNullOrWhiteSpace(_config.DuckDnsDomain) ||
            string.IsNullOrWhiteSpace(_config.DuckDnsToken))
        {
            return;
        }

        using var timer = new PeriodicTimer(TimeSpan.FromMinutes(5));
        await UpdateOnceAsync(stoppingToken);

        while (await timer.WaitForNextTickAsync(stoppingToken))
        {
            await UpdateOnceAsync(stoppingToken);
        }
    }

    private async Task UpdateOnceAsync(CancellationToken token)
    {
        try
        {
            var domain = _config.DuckDnsDomain.Replace(".duckdns.org", "", StringComparison.OrdinalIgnoreCase).Trim();
            var url = $"https://www.duckdns.org/update?domains={Uri.EscapeDataString(domain)}&token={Uri.EscapeDataString(_config.DuckDnsToken.Trim())}&ip=";
            var res = (await Http.GetStringAsync(url, token)).Trim();
            _log($"[DuckDNS] 갱신 응답({domain}.duckdns.org): {res}");
        }
        catch (Exception ex) when (!token.IsCancellationRequested)
        {
            _log($"[DuckDNS 오류] {ex.Message}");
        }
    }
}
