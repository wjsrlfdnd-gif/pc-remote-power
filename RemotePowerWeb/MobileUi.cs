using System.Net;
using System.Reflection;

namespace RemotePowerWeb;

/// <summary>
/// 스마트폰 홈 화면에 정식 PWA로 설치할 수 있는 UI, 매니페스트, 서비스 워커, PNG 아이콘을 제공합니다.
/// </summary>
public static class MobileUi
{
    public const string ServiceWorkerJs = """
const CACHE_NAME = 'pc-remote-power-v2';
const SHELL_ASSETS = ['/', '/manifest.webmanifest', '/icon-192.png', '/icon-512.png'];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_ASSETS))
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== 'GET' || url.pathname.startsWith('/api/')) {
    return;
  }

  if (event.request.mode === 'navigate' || url.pathname === '/') {
    event.respondWith(
      fetch(event.request)
        .then((res) => {
          const copy = res.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put('/', copy));
          return res;
        })
        .catch(() => caches.match('/'))
    );
    return;
  }

  event.respondWith(
    caches.match(event.request).then((cached) => cached || fetch(event.request))
  );
});
""";

    public static byte[]? ReadEmbeddedPng(string fileName)
    {
        var asm = Assembly.GetExecutingAssembly();
        var resourceName = $"RemotePowerWeb.Assets.{fileName}";
        using var stream = asm.GetManifestResourceStream(resourceName);
        if (stream is null)
        {
            return null;
        }

        using var ms = new MemoryStream();
        stream.CopyTo(ms);
        return ms.ToArray();
    }

    public static string BuildManifest(string pcName)
    {
        var safeName = WebUtility.HtmlEncode(pcName);
        return $$"""
{
  "id": "/",
  "name": "{{safeName}} 원격 전원",
  "short_name": "PC 전원",
  "description": "스마트폰 원클릭 PC 전원 및 Antigravity 제어 앱",
  "start_url": "/",
  "scope": "/",
  "display": "standalone",
  "orientation": "portrait",
  "background_color": "#0b1120",
  "theme_color": "#0b1120",
  "icons": [
    {
      "src": "/icon-192.png",
      "sizes": "192x192",
      "type": "image/png",
      "purpose": "any"
    },
    {
      "src": "/icon-512.png",
      "sizes": "512x512",
      "type": "image/png",
      "purpose": "any"
    }
  ]
}
""";
    }

    public static string BuildHtml(string pcName, int delaySeconds)
    {
        var safeName = WebUtility.HtmlEncode(pcName);
        return $$"""
<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
  <meta name="apple-mobile-web-app-capable" content="yes" />
  <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent" />
  <meta name="mobile-web-app-capable" content="yes" />
  <meta name="theme-color" content="#0b1120" />
  <link rel="manifest" href="/manifest.webmanifest" />
  <link rel="icon" type="image/png" sizes="192x192" href="/icon-192.png" />
  <link rel="apple-touch-icon" sizes="192x192" href="/icon-192.png" />
  <title>{{safeName}} 원격 전원</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #0b1120;
      --card: #131c31;
      --border: #24324d;
      --text: #f1f5f9;
      --muted: #94a3b8;
    }
    * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
    body {
      margin: 0;
      min-height: 100dvh;
      font-family: -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", "Noto Sans KR", sans-serif;
      background: radial-gradient(circle at top, #172554 0%, var(--bg) 55%);
      color: var(--text);
      display: flex;
      justify-content: center;
      padding: max(20px, env(safe-area-inset-top)) 16px max(24px, env(safe-area-inset-bottom));
    }
    .wrap { width: 100%; max-width: 440px; display: flex; flex-direction: column; gap: 14px; }
    .card {
      background: rgba(19, 28, 49, 0.92);
      border: 1px solid var(--border);
      border-radius: 20px;
      padding: 18px;
      backdrop-filter: blur(12px);
    }
    .header { display: flex; justify-content: space-between; align-items: center; gap: 10px; }
    h1 { margin: 0; font-size: 20px; font-weight: 700; }
    .badge {
      display: inline-flex; align-items: center; gap: 6px;
      font-size: 13px; font-weight: 600;
      padding: 6px 12px; border-radius: 999px;
      background: rgba(34, 197, 94, 0.14); color: #86efac; border: 1px solid rgba(34, 197, 94, 0.35);
    }
    .badge.off { background: rgba(148, 163, 184, 0.14); color: var(--muted); border-color: var(--border); }
    .meta { margin-top: 12px; font-size: 13px; color: var(--muted); line-height: 1.55; word-break: break-all; white-space: pre-line; }
    .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
    button {
      border: 0; border-radius: 16px; color: white; font-weight: 700; font-size: 16px;
      padding: 18px 14px; cursor: pointer; display: flex; flex-direction: column;
      align-items: center; justify-content: center; gap: 6px;
      transition: transform 0.08s ease, opacity 0.15s ease;
    }
    button:active { transform: scale(0.97); }
    button:disabled { opacity: 0.5; cursor: not-allowed; }
    .btn-agy { background: linear-gradient(135deg, #7c3aed, #5b21b6); grid-column: span 2; padding: 18px; font-size: 17px; }
    .btn-off { background: linear-gradient(135deg, #dc2626, #b91c1c); grid-column: span 2; padding: 22px; font-size: 18px; }
    .btn-sleep { background: linear-gradient(135deg, #2563eb, #1d4ed8); }
    .btn-reboot { background: linear-gradient(135deg, #d97706, #b45309); }
    .btn-cancel { background: #334155; grid-column: span 2; padding: 14px; font-size: 15px; }
    .btn-install {
      background: linear-gradient(135deg, #0ea5e9, #2563eb);
      width: 100%; padding: 14px; font-size: 15px; flex-direction: row;
    }
    .btn-small {
      background: #1e293b; border: 1px solid var(--border); border-radius: 10px;
      padding: 8px 12px; font-size: 13px; flex-direction: row; width: auto;
    }
    .sub { font-size: 12px; font-weight: 500; opacity: 0.85; }
    .row { display: flex; justify-content: space-between; align-items: center; gap: 12px; font-size: 14px; }
    input[type="password"], input[type="text"] {
      width: 100%; padding: 12px 14px; border-radius: 12px; border: 1px solid var(--border);
      background: #0b1120; color: var(--text); font-size: 14px; margin-top: 8px;
    }
    .toast {
      padding: 12px 14px; border-radius: 14px; font-size: 14px; line-height: 1.45;
      background: #1e293b; border: 1px solid var(--border); display: none;
    }
    .toast.show { display: block; }
    .toast.ok { border-color: rgba(34, 197, 94, 0.5); color: #bbf7d0; }
    .toast.err { border-color: rgba(239, 68, 68, 0.5); color: #fecaca; }
    details summary { cursor: pointer; font-weight: 600; font-size: 14px; color: #cbd5e1; }
    code { background: #0b1120; padding: 2px 6px; border-radius: 6px; font-size: 12px; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <div class="header">
        <h1>🖥️ {{safeName}}</h1>
        <span id="statusBadge" class="badge off">확인 중...</span>
      </div>
      <div id="statusMeta" class="meta">상태를 불러오는 중입니다.</div>
      <div style="margin-top:12px; display:flex; gap:8px; flex-wrap:wrap;">
        <button class="btn-small" onclick="refreshStatus()">↻ 새로고침</button>
        <button class="btn-small" onclick="toggleTokenPanel()">🔑 토큰 설정</button>
      </div>
    </div>

    <div id="installCard" class="card" style="display:none;">
      <button class="btn-install" onclick="installPwa()">📲 홈 화면에 앱으로 설치</button>
    </div>

    <div id="tokenCard" class="card" style="display:none;">
      <div style="font-weight:700; font-size:15px;">API 인증 토큰 입력</div>
      <div class="meta" style="margin-top:4px;">설정 시 발급된 ApiToken을 한 번만 입력하면 이 기기에 저장됩니다.</div>
      <input id="tokenInput" type="password" placeholder="ApiToken 붙여넣기" />
      <button class="btn-small" style="margin-top:10px; width:100%; background:#2563eb;" onclick="saveToken()">저장 및 연결</button>
    </div>

    <div id="toast" class="toast"></div>

    <div class="card">
      <div class="grid">
        <button class="btn-agy" onclick="triggerEndpoint('/api/app/antigravity/start', null, true)">
          <span>🚀 Antigravity 켜기</span>
          <span class="sub">PC에서 Remote Control 앱 실행</span>
        </button>
        <button class="btn-off" onclick="triggerPower('shutdown', 'PC를 종료')">
          <span>⏻ 전원 끄기</span>
          <span class="sub">{{delaySeconds}}초 후 정상 종료</span>
        </button>
        <button class="btn-sleep" onclick="triggerPower('sleep', '절전 모드로 전환')">
          <span>🌙 절전 모드</span>
          <span class="sub">S3 대기 전환</span>
        </button>
        <button class="btn-reboot" onclick="triggerPower('reboot', '다시 시작')">
          <span>🔄 다시 시작</span>
          <span class="sub">{{delaySeconds}}초 후 재부팅</span>
        </button>
        <button class="btn-cancel" onclick="triggerPower('cancel', null)">
          <span>❌ 예약된 종료/재부팅 취소</span>
        </button>
      </div>
      <div class="row" style="margin-top:14px; padding-top:14px; border-top:1px solid var(--border);">
        <span>확인 창 없이 원클릭 즉시 실행</span>
        <input id="oneClickToggle" type="checkbox" style="width:20px; height:20px;" onchange="saveOneClickPref()" />
      </div>
    </div>

    <div class="card">
      <details>
        <summary>📱 앱 설치 &amp; 원터치 단축어 설정 방법</summary>
        <div class="meta">
          <p><strong>1. 스마트폰 앱으로 설치 (PWA)</strong><br/>
          - Cloudflare Tunnel(<code>cloudflared</code>) HTTPS 주소로 열면 VPN 없이 Android Chrome에서 '앱 설치' 버튼이 바로 뜹니다.<br/>
          - iPhone Safari는 <code>공유 → 홈 화면에 추가</code> 로 설치하세요.</p>
          <p><strong>2. 아이폰 단축어 / 안드로이드 HTTP Shortcuts (완전 1터치)</strong><br/>
          - Method: <code>POST</code><br/>
          - 종료 URL: <code id="shortcutShutdownUrl"></code><br/>
          - 절전 URL: <code id="shortcutSleepUrl"></code><br/>
          - Antigravity 켜기 URL: <code id="shortcutAgyUrl"></code><br/>
          - Header: <code>X-Auth-Token: (발급된 토큰)</code></p>
        </div>
      </details>
    </div>
  </div>

  <script>
    const TOKEN_KEY = 'pc_remote_power_token';
    const ONECLICK_KEY = 'pc_remote_power_oneclick';
    let deferredInstallPrompt = null;

    if ('serviceWorker' in navigator) {
      navigator.serviceWorker.register('/sw.js').catch(() => {});
    }

    window.addEventListener('beforeinstallprompt', (e) => {
      e.preventDefault();
      deferredInstallPrompt = e;
      document.getElementById('installCard').style.display = 'block';
    });

    window.addEventListener('appinstalled', () => {
      deferredInstallPrompt = null;
      document.getElementById('installCard').style.display = 'none';
      showToast('앱 설치가 완료되었습니다!', true);
    });

    async function installPwa() {
      if (!deferredInstallPrompt) return;
      deferredInstallPrompt.prompt();
      await deferredInstallPrompt.userChoice;
      deferredInstallPrompt = null;
      document.getElementById('installCard').style.display = 'none';
    }

    function initFromQuery() {
      const params = new URLSearchParams(window.location.search);
      const urlToken = params.get('token');
      if (urlToken) {
        localStorage.setItem(TOKEN_KEY, urlToken.trim());
        params.delete('token');
        const cleanUrl = window.location.pathname + (params.toString() ? '?' + params.toString() : '');
        window.history.replaceState({}, '', cleanUrl);
      }
      document.getElementById('oneClickToggle').checked = localStorage.getItem(ONECLICK_KEY) === '1';
      document.getElementById('shortcutShutdownUrl').textContent = window.location.origin + '/api/power/shutdown';
      document.getElementById('shortcutSleepUrl').textContent = window.location.origin + '/api/power/sleep';
      document.getElementById('shortcutAgyUrl').textContent = window.location.origin + '/api/app/antigravity/start';
    }

    function getToken() {
      return localStorage.getItem(TOKEN_KEY) || '';
    }

    function toggleTokenPanel(forceShow) {
      const card = document.getElementById('tokenCard');
      card.style.display = (forceShow === true || card.style.display === 'none') ? 'block' : 'none';
    }

    function saveToken() {
      const val = document.getElementById('tokenInput').value.trim();
      if (!val) return showToast('토큰을 입력하세요.', false);
      localStorage.setItem(TOKEN_KEY, val);
      document.getElementById('tokenInput').value = '';
      toggleTokenPanel(false);
      refreshStatus();
    }

    function saveOneClickPref() {
      const checked = document.getElementById('oneClickToggle').checked;
      localStorage.setItem(ONECLICK_KEY, checked ? '1' : '0');
    }

    function showToast(msg, ok) {
      const el = document.getElementById('toast');
      el.textContent = msg;
      el.className = 'toast show ' + (ok ? 'ok' : 'err');
    }

    async function refreshStatus() {
      const badge = document.getElementById('statusBadge');
      const meta = document.getElementById('statusMeta');
      const token = getToken();
      if (!token) {
        badge.textContent = '토큰 필요';
        badge.className = 'badge off';
        meta.textContent = '아래에 ApiToken을 입력하거나 설정 스크립트가 생성한 접속 링크로 열어주세요.';
        toggleTokenPanel(true);
        return;
      }

      try {
        const res = await fetch('/api/status', { headers: { 'X-Auth-Token': token } });
        if (res.status === 401 || res.status === 429) {
          badge.textContent = '인증 실패';
          badge.className = 'badge off';
          meta.textContent = '토큰이 올바르지 않습니다. 다시 입력해 주세요.';
          toggleTokenPanel(true);
          return;
        }
        const data = await res.json();
        badge.textContent = '🟢 온라인';
        badge.className = 'badge';
        const nics = (data.adapters || [])
          .filter(a => a.isUp)
          .map(a => `${a.name}: ${a.iPv4 || a.ipv4} (MAC ${a.macAddress})`)
          .join(' | ');
        const agyState = data.antigravityRunning
          ? '🟢 실행 중'
          : (data.userSessionActive ? '⚫ 꺼짐 (실행 가능)' : '🔒 꺼짐 (Windows 로그인 필요)');
        meta.textContent = `가동 시간: ${data.uptimeText}\nAntigravity: ${agyState}${nics ? '\n' + nics : ''}`;
      } catch (e) {
        badge.textContent = '⚫ 오프라인';
        badge.className = 'badge off';
        meta.textContent = 'PC에 연결할 수 없습니다. 꺼져 있거나 네트워크를 확인하세요.';
      }
    }

    async function triggerPower(action, confirmLabel) {
      return triggerEndpoint('/api/power/' + action, confirmLabel, false);
    }

    async function triggerEndpoint(path, confirmLabel, refreshAfter) {
      const token = getToken();
      if (!token) {
        toggleTokenPanel(true);
        return showToast('먼저 API 토큰을 저장해 주세요.', false);
      }

      const skipConfirm = document.getElementById('oneClickToggle').checked;
      if (confirmLabel && !skipConfirm) {
        if (!window.confirm(`정말 ${confirmLabel}할까요?`)) return;
      }

      try {
        const res = await fetch(path, {
          method: 'POST',
          headers: { 'X-Auth-Token': token }
        });
        const data = await res.json().catch(() => ({ message: '응답 해석 실패' }));
        showToast(data.message || (res.ok ? '실행 완료' : '요청 실패'), res.ok && data.success !== false);
        if (refreshAfter) setTimeout(refreshStatus, 1800);
      } catch (e) {
        showToast('요청 전송 실패: ' + e.message, false);
      }
    }

    initFromQuery();
    refreshStatus();
  </script>
</body>
</html>
""";
    }
}
