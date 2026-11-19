using System.Collections.Concurrent;
using System.Net;
using System.Security.Cryptography;
using System.Text;

namespace RemotePowerWeb;

/// <summary>
/// 상수 시간 토큰 비교 및 잘못된 토큰 시도 횟수 제한을 처리합니다.
/// </summary>
public sealed class TokenAuthGuard
{
    private sealed class AttemptRecord
    {
        public int Count;
        public DateTimeOffset WindowStartUtc;
        public DateTimeOffset BlockedUntilUtc;
    }

    private readonly byte[] _expectedTokenBytes;
    private readonly ConcurrentDictionary<string, AttemptRecord> _attempts = new();

    public TokenAuthGuard(string expectedToken)
    {
        _expectedTokenBytes = Encoding.UTF8.GetBytes(expectedToken);
    }

    /// <summary>
    /// cloudflared 등 로컬 루프백 리버스 프록시를 경유한 경우 CF-Connecting-IP / X-Forwarded-For에서 실제 클라이언트 IP를 추출합니다.
    /// </summary>
    public static string ResolveClientIp(HttpContext context)
    {
        var remoteIp = context.Connection.RemoteIpAddress;
        if (remoteIp is null)
        {
            return "unknown";
        }

        var normalized = remoteIp.IsIPv4MappedToIPv6 ? remoteIp.MapToIPv4() : remoteIp;
        if (IPAddress.IsLoopback(normalized))
        {
            if (context.Request.Headers.TryGetValue("CF-Connecting-IP", out var cfIp))
            {
                var value = cfIp.ToString().Trim();
                if (!string.IsNullOrEmpty(value) && value.Length <= 64)
                {
                    return value;
                }
            }

            if (context.Request.Headers.TryGetValue("X-Forwarded-For", out var xff))
            {
                var first = xff.ToString().Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).FirstOrDefault();
                if (!string.IsNullOrEmpty(first) && first.Length <= 64)
                {
                    return first;
                }
            }
        }

        return normalized.ToString();
    }

    public (bool Authorized, int StatusCode, string ErrorMessage) Authorize(HttpContext context)
    {
        var ipKey = ResolveClientIp(context);
        var now = DateTimeOffset.UtcNow;

        if (_attempts.TryGetValue(ipKey, out var existing) && existing.BlockedUntilUtc > now)
        {
            return (false, StatusCodes.Status429TooManyRequests, "인증 실패 횟수가 많아 잠시 차단되었습니다. 5분 뒤 다시 시도하세요.");
        }

        var provided = ExtractToken(context.Request);
        if (!string.IsNullOrEmpty(provided))
        {
            var providedBytes = Encoding.UTF8.GetBytes(provided);
            if (providedBytes.Length == _expectedTokenBytes.Length &&
                CryptographicOperations.FixedTimeEquals(providedBytes, _expectedTokenBytes))
            {
                _attempts.TryRemove(ipKey, out _);
                return (true, StatusCodes.Status200OK, string.Empty);
            }
        }

        var record = _attempts.GetOrAdd(ipKey, _ => new AttemptRecord { WindowStartUtc = now });
        lock (record)
        {
            if (now - record.WindowStartUtc > TimeSpan.FromMinutes(1))
            {
                record.Count = 0;
                record.WindowStartUtc = now;
            }

            record.Count++;
            if (record.Count >= 10)
            {
                record.BlockedUntilUtc = now.AddMinutes(5);
            }
        }

        return (false, StatusCodes.Status401Unauthorized, "유효한 API 토큰이 필요합니다.");
    }

    private static string? ExtractToken(HttpRequest request)
    {
        if (request.Headers.TryGetValue("X-Auth-Token", out var headerVal) &&
            !string.IsNullOrWhiteSpace(headerVal.ToString()))
        {
            return headerVal.ToString().Trim();
        }

        if (request.Headers.TryGetValue("Authorization", out var authVal))
        {
            var raw = authVal.ToString().Trim();
            if (raw.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            {
                return raw["Bearer ".Length..].Trim();
            }
        }

        if (request.Query.TryGetValue("token", out var queryVal) &&
            !string.IsNullOrWhiteSpace(queryVal.ToString()))
        {
            return queryVal.ToString().Trim();
        }

        return null;
    }
}
