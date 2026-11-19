#!/usr/bin/env python3
"""
집 안 상시 구동 기기(안드로이드 공기계 Termux / 라즈베리파이 / 리눅스 / 미니PC)에서 실행하는
통합 PC 원격 전원 ON/OFF + PWA 앱 중계 서버입니다. (외부 패키지 설치 불필요 - Python 3 표준 라이브러리만 사용)
VPN이나 공유기 포트포워딩 없이 Cloudflare Tunnel(cloudflared)을 내장 실행하여 자동 HTTPS 원격 접속을 지원합니다.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import http.server
import ipaddress
import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
ROOT_DIR = BASE_DIR.parent
CONFIG_PATH = BASE_DIR / "relay-config.json"
TUNNEL_URL_PATH = BASE_DIR / "tunnel-url.txt"
DEFAULT_PWA_BASE_URL = "https://wjsrlfdnd-gif.github.io/pc-remote-power/"
DEFAULT_SYNC_SERVER = "https://ntfy.sh"
SYNC_HEARTBEAT_SEC = 10800  # 3시간마다 주소 재발행 (ntfy 12시간 캐시 만료 방지)
TRYCLOUDFLARE_RE = re.compile(r"https://[a-z0-9-]+\.trycloudflare\.com", re.IGNORECASE)


def derive_sync_topic(token: str, explicit_topic: str = "") -> str:
    clean_explicit = (explicit_topic or "").strip()
    if clean_explicit:
        return clean_explicit
    clean_token = (token or "").strip()
    if not clean_token:
        return ""
    digest = hashlib.sha256(f"pcrp-sync:{clean_token}".encode("utf-8")).hexdigest()[:24]
    return f"pcrp-{digest}"


def detect_default_broadcast() -> str:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            local_ip = s.getsockname()[0]
        parts = local_ip.split(".")
        if len(parts) == 4:
            return f"{parts[0]}.{parts[1]}.{parts[2]}.255"
    except Exception:
        pass
    return "192.168.0.255"


def load_icon_bytes(file_name: str) -> bytes | None:
    for candidate in (BASE_DIR / file_name, ROOT_DIR / file_name):
        if candidate.is_file():
            return candidate.read_bytes()
    return None


def find_cloudflared_binary() -> str | None:
    found = shutil.which("cloudflared")
    if found:
        return found
    candidates = [
        Path.home() / ".local" / "bin" / "cloudflared",
        Path("/usr/local/bin/cloudflared"),
        Path("/usr/bin/cloudflared"),
        Path("/data/data/com.termux/files/usr/bin/cloudflared"),
        ROOT_DIR / "tools" / "cloudflared.exe",
        Path(r"C:\Program Files (x86)\cloudflared\cloudflared.exe"),
        Path(r"C:\Program Files\cloudflared\cloudflared.exe"),
    ]
    for path in candidates:
        if path.is_file():
            return str(path)
    return None


def build_pwa_setup_link(
    public_url: str,
    pc_name: str,
    pwa_base_url: str = DEFAULT_PWA_BASE_URL,
    sync_topic: str = "",
) -> str:
    base = (pwa_base_url or DEFAULT_PWA_BASE_URL).strip()
    if not base:
        base = DEFAULT_PWA_BASE_URL
    params = {"server": public_url.rstrip("/"), "mode": "relay"}
    if pc_name:
        params["name"] = pc_name
    if sync_topic:
        params["sync"] = sync_topic
    sep = "&" if "?" in base else "?"
    return f"{base}{sep}{urllib.parse.urlencode(params)}"


def ensure_config(force_setup: bool = False) -> dict:
    existing: dict = {}
    if CONFIG_PATH.exists():
        with CONFIG_PATH.open("r", encoding="utf-8") as f:
            existing = json.load(f)
        if not force_setup:
            updated = False
            if not existing.get("tunnel_mode"):
                existing["tunnel_mode"] = "quick"
                updated = True
            expected_sync = derive_sync_topic(existing.get("relay_token", ""), existing.get("sync_topic", ""))
            if expected_sync and existing.get("sync_topic") != expected_sync:
                existing["sync_topic"] = expected_sync
                updated = True
            if updated:
                try:
                    with CONFIG_PATH.open("w", encoding="utf-8") as wf:
                        json.dump(existing, wf, ensure_ascii=False, indent=2)
                except Exception:
                    pass
            return existing

    print("=" * 60)
    print("  PC 원격 전원 중계기(WoL + OFF + VPN 없는 Cloudflare 터널) 설정")
    print("=" * 60)

    default_broadcast = existing.get("broadcast_ip") or detect_default_broadcast()
    default_pc_name = existing.get("pc_name") or "My-PC"
    default_pc_mac = existing.get("pc_mac") or ""
    default_pc_ip = existing.get("pc_ip") or ""
    default_pc_port = str(existing.get("pc_web_port") or 18080)
    default_pc_token = existing.get("pc_web_token") or ""
    default_relay_port = str(existing.get("relay_port") or 18090)

    pc_name = input(f"PC 표시 이름 [기본값: {default_pc_name}]: ").strip() or default_pc_name
    pc_mac = input(f"대상 PC 유선 랜 MAC 주소 (예: AA-BB-CC-DD-EE-FF){f' [현재: {default_pc_mac}]' if default_pc_mac else ''}: ").strip() or default_pc_mac
    while not pc_mac:
        pc_mac = input("대상 PC MAC 주소는 필수입니다: ").strip()

    pc_ip = input(f"대상 PC 내부 IP (예: 192.168.0.10){f' [현재: {default_pc_ip}]' if default_pc_ip else ''}: ").strip() or default_pc_ip
    while not pc_ip:
        pc_ip = input("대상 PC 내부 IP는 필수입니다: ").strip()

    pc_web_port_raw = input(f"대상 PC RemotePowerWeb 포트 [기본값: {default_pc_port}]: ").strip() or default_pc_port
    pc_web_token = input(f"대상 PC web-config.json의 ApiToken{' [엔터 시 기존 유지]' if default_pc_token else ''}: ").strip() or default_pc_token
    while not pc_web_token:
        pc_web_token = input("대상 PC ApiToken은 필수입니다: ").strip()

    broadcast_ip = input(f"공유기 브로드캐스트 IP [기본값: {default_broadcast}]: ").strip() or default_broadcast
    relay_port_raw = input(f"이 중계 서버가 사용할 포트 [기본값: {default_relay_port}]: ").strip() or default_relay_port
    relay_token = input("폰 접속용 중계기 토큰 [엔터 시 PC ApiToken과 동일, 'auto' 입력 시 랜덤 생성]: ").strip()
    if relay_token.lower() == "auto":
        relay_token = secrets.token_urlsafe(24)
    elif not relay_token:
        relay_token = existing.get("relay_token") or pc_web_token

    print("\n[외부 접속 방식 - VPN·포트포워딩 불필요]")
    print("  1) quick : Cloudflare Quick Tunnel (계정·도메인 없이 즉시 무료 HTTPS 생성, 기본값)")
    print("  2) token : Cloudflare Named Tunnel (무료 Cloudflare 계정 + 영구 고정 HTTPS 주소)")
    print("  3) none  : 터널 미사용 (집 안 Wi-Fi 또는 직접 포트포워딩만 사용)")
    tunnel_choice = input("선택 [1/2/3, 기본값: 1]: ").strip().lower()
    if tunnel_choice in ("2", "token"):
        tunnel_mode = "token"
    elif tunnel_choice in ("3", "none"):
        tunnel_mode = "none"
    else:
        tunnel_mode = "quick"

    cloudflare_tunnel_token = ""
    public_url = ""
    notify_webhook_url = existing.get("notify_webhook_url", "")
    if tunnel_mode == "token":
        cloudflare_tunnel_token = input("Cloudflare Tunnel 토큰 (eyJh...): ").strip() or existing.get("cloudflare_tunnel_token", "")
        public_url = input("연결한 고정 HTTPS 주소 (예: https://pc.example.com, 안내용/선택): ").strip().rstrip("/") or existing.get("public_url", "")
    elif tunnel_mode == "quick":
        print("  (선택) 재부팅 시 바뀌는 Quick Tunnel 새 주소를 폰으로 자동 알림 받으려면")
        print("  Discord Webhook URL 또는 ntfy.sh 주소(예: https://ntfy.sh/나만의비밀토픽)를 입력하세요.")
        notify_webhook_url = input(f"알림 웹훅 URL (미사용 시 엔터){f' [현재 설정됨]' if notify_webhook_url else ''}: ").strip() or notify_webhook_url

    duckdns_domain = input("DuckDNS 도메인 (선택, 미사용 시 엔터): ").strip()
    duckdns_token = input("DuckDNS 토큰 (선택, 미사용 시 엔터): ").strip() if duckdns_domain else ""

    cfg = {
        "pc_name": pc_name,
        "pc_mac": pc_mac,
        "pc_ip": pc_ip,
        "pc_web_port": int(pc_web_port_raw),
        "pc_web_token": pc_web_token,
        "broadcast_ip": broadcast_ip,
        "relay_port": int(relay_port_raw),
        "relay_token": relay_token,
        "tunnel_mode": tunnel_mode,
        "cloudflare_tunnel_token": cloudflare_tunnel_token,
        "public_url": public_url,
        "notify_webhook_url": notify_webhook_url,
        "sync_topic": derive_sync_topic(relay_token, existing.get("sync_topic", "")),
        "pwa_base_url": existing.get("pwa_base_url") or DEFAULT_PWA_BASE_URL,
        "duckdns_domain": duckdns_domain,
        "duckdns_token": duckdns_token,
    }

    with CONFIG_PATH.open("w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)

    print(f"\n[저장 완료] {CONFIG_PATH}\n")
    return cfg


def send_magic_packet(mac_str: str, broadcast_ip: str) -> None:
    cleaned = mac_str.replace("-", "").replace(":", "").replace(".", "").strip()
    if len(cleaned) != 12:
        raise ValueError(f"유효하지 않은 MAC 주소입니다: {mac_str}")
    mac_bytes = bytes.fromhex(cleaned)
    packet = b"\xff" * 6 + mac_bytes * 16

    targets = []
    for ip in (broadcast_ip, "255.255.255.255"):
        if ip and ip not in targets:
            targets.append(ip)

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        for target in targets:
            for port in (9, 7):
                sock.sendto(packet, (target, port))


def call_pc_web(cfg: dict, method: str, path: str, timeout: float = 2.5) -> tuple[int, dict]:
    url = f"http://{cfg['pc_ip']}:{cfg['pc_web_port']}{path}"
    req = urllib.request.Request(
        url,
        method=method,
        data=b"" if method == "POST" else None,
        headers={"X-Auth-Token": cfg["pc_web_token"]},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            return resp.status, json.loads(body) if body else {"success": True}
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        try:
            data = json.loads(body)
        except Exception:
            data = {"success": False, "message": body or str(e)}
        return e.code, data
    except Exception as e:
        return 503, {"success": False, "message": f"PC에 연결할 수 없습니다(전원이 꺼져 있거나 부팅 중): {e}"}


SERVICE_WORKER_JS = """const CACHE_NAME = 'pc-relay-pwa-v2';
const SHELL_ASSETS = ['/', '/manifest.webmanifest', '/icon-192.png', '/icon-512.png'];
self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE_NAME).then((c) => c.addAll(SHELL_ASSETS)));
  self.skipWaiting();
});
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))));
  self.clients.claim();
});
self.addEventListener('fetch', (e) => {
  const u = new URL(e.request.url);
  if (e.request.method !== 'GET' || u.pathname.startsWith('/api/')) return;
  if (e.request.mode === 'navigate' || u.pathname === '/') {
    e.respondWith(fetch(e.request).then((r) => { const c = r.clone(); caches.open(CACHE_NAME).then((cache) => cache.put('/', c)); return r; }).catch(() => caches.match('/')));
    return;
  }
  e.respondWith(caches.match(e.request).then((c) => c || fetch(e.request)));
});
"""

ICON_SVG = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 192 192"><rect width="192" height="192" rx="44" fill="#0f172a"/><path d="M96 42v48" stroke="#22c55e" stroke-width="14" stroke-linecap="round"/><path d="M62 64a46 46 0 1 0 68 0" fill="none" stroke="#22c55e" stroke-width="14" stroke-linecap="round"/></svg>"""


def build_html(cfg: dict) -> str:
    pc_name = cfg["pc_name"]
    return f"""<!DOCTYPE html>
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
  <title>{pc_name} 통합 전원</title>
  <style>
    :root {{ color-scheme: dark; --bg:#0b1120; --card:#131c31; --border:#24324d; --text:#f1f5f9; --muted:#94a3b8; }}
    * {{ box-sizing:border-box; -webkit-tap-highlight-color:transparent; }}
    body {{
      margin:0; min-height:100dvh; color:var(--text);
      font-family:-apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo","Noto Sans KR",sans-serif;
      background:radial-gradient(circle at top,#172554 0%,var(--bg) 55%);
      display:flex; justify-content:center;
      padding:max(20px,env(safe-area-inset-top)) 16px max(24px,env(safe-area-inset-bottom));
    }}
    .wrap {{ width:100%; max-width:440px; display:flex; flex-direction:column; gap:14px; }}
    .card {{ background:rgba(19,28,49,.92); border:1px solid var(--border); border-radius:20px; padding:18px; }}
    .header {{ display:flex; justify-content:space-between; align-items:center; gap:10px; }}
    h1 {{ margin:0; font-size:20px; }}
    .badge {{ font-size:13px; font-weight:600; padding:6px 12px; border-radius:999px; background:rgba(34,197,94,.14); color:#86efac; border:1px solid rgba(34,197,94,.35); }}
    .badge.off {{ background:rgba(148,163,184,.14); color:var(--muted); border-color:var(--border); }}
    .meta {{ margin-top:10px; font-size:13px; color:var(--muted); line-height:1.55; word-break:break-all; white-space:pre-line; }}
    .grid {{ display:grid; grid-template-columns:1fr 1fr; gap:12px; }}
    button {{
      border:0; border-radius:16px; color:#fff; font-weight:700; font-size:16px; padding:18px 14px;
      cursor:pointer; display:flex; flex-direction:column; align-items:center; gap:5px;
    }}
    button:active {{ transform:scale(0.97); }}
    .btn-on {{ background:linear-gradient(135deg,#16a34a,#15803d); grid-column:span 2; padding:22px; font-size:18px; }}
    .btn-agy {{ background:linear-gradient(135deg,#7c3aed,#5b21b6); grid-column:span 2; padding:18px; font-size:17px; }}
    .btn-off {{ background:linear-gradient(135deg,#dc2626,#b91c1c); grid-column:span 2; padding:20px; font-size:17px; }}
    .btn-sleep {{ background:linear-gradient(135deg,#2563eb,#1d4ed8); }}
    .btn-reboot {{ background:linear-gradient(135deg,#d97706,#b45309); }}
    .btn-cancel {{ background:#334155; grid-column:span 2; padding:14px; font-size:15px; }}
    .btn-install {{ background:linear-gradient(135deg,#0ea5e9,#2563eb); width:100%; padding:14px; font-size:15px; flex-direction:row; justify-content:center; }}
    .btn-small {{ background:#1e293b; border:1px solid var(--border); border-radius:10px; padding:8px 12px; font-size:13px; flex-direction:row; }}
    .sub {{ font-size:12px; font-weight:500; opacity:.85; }}
    .row {{ display:flex; justify-content:space-between; align-items:center; margin-top:14px; padding-top:14px; border-top:1px solid var(--border); font-size:14px; }}
    input[type="password"] {{ width:100%; padding:12px; border-radius:12px; border:1px solid var(--border); background:#0b1120; color:var(--text); margin-top:8px; }}
    .toast {{ padding:12px 14px; border-radius:14px; font-size:14px; background:#1e293b; border:1px solid var(--border); display:none; }}
    .toast.show {{ display:block; }}
    .toast.ok {{ border-color:rgba(34,197,94,.5); color:#bbf7d0; }}
    .toast.err {{ border-color:rgba(239,68,68,.5); color:#fecaca; }}
    code {{ background:#0b1120; padding:2px 6px; border-radius:6px; font-size:12px; }}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <div class="header">
        <h1>🖥️ {pc_name}</h1>
        <span id="statusBadge" class="badge off">확인 중...</span>
      </div>
      <div id="statusMeta" class="meta">PC 상태를 확인하는 중입니다.</div>
      <div style="margin-top:12px; display:flex; gap:8px;">
        <button class="btn-small" onclick="refreshStatus()">↻ 새로고침</button>
        <button class="btn-small" onclick="toggleTokenPanel()">🔑 토큰 설정</button>
      </div>
    </div>

    <div id="installCard" class="card" style="display:none;">
      <button class="btn-install" onclick="installPwa()">📲 홈 화면에 앱으로 설치</button>
    </div>

    <div id="tokenCard" class="card" style="display:none;">
      <div style="font-weight:700;">인증 토큰 입력</div>
      <input id="tokenInput" type="password" placeholder="relay_token 입력" />
      <button class="btn-small" style="margin-top:10px; width:100%; background:#2563eb;" onclick="saveToken()">저장 및 연결</button>
    </div>

    <div id="toast" class="toast"></div>

    <div class="card">
      <div class="grid">
        <button class="btn-on" onclick="trigger('on', null)">
          <span>⚡ PC 켜기 (WoL)</span>
          <span class="sub">집 내부망 매직 패킷 즉시 전송</span>
        </button>
        <button class="btn-agy" onclick="trigger('antigravity/start', null)">
          <span>🚀 Antigravity 켜기</span>
          <span class="sub">PC에서 Remote Control 앱 실행</span>
        </button>
        <button class="btn-off" onclick="trigger('off', 'PC를 종료')">
          <span>⏻ 전원 끄기</span>
          <span class="sub">Windows 정상 종료</span>
        </button>
        <button class="btn-sleep" onclick="trigger('sleep', '절전 모드로 전환')">
          <span>🌙 절전 모드</span>
          <span class="sub">S3 대기</span>
        </button>
        <button class="btn-reboot" onclick="trigger('reboot', '다시 시작')">
          <span>🔄 다시 시작</span>
          <span class="sub">재부팅</span>
        </button>
        <button class="btn-cancel" onclick="trigger('cancel', null)">
          <span>❌ 예약된 종료/재부팅 취소</span>
        </button>
      </div>
      <div class="row">
        <span>확인 창 없이 원클릭 즉시 실행</span>
        <input id="oneClickToggle" type="checkbox" style="width:20px; height:20px;" onchange="saveOneClickPref()" />
      </div>
    </div>

    <div class="card">
      <details>
        <summary style="cursor:pointer; font-weight:600; font-size:14px;">📱 앱 설치 &amp; 원터치 위젯 주소</summary>
        <div class="meta">
          - Method: <code>POST</code> / Header: <code>X-Auth-Token: (토큰)</code><br/>
          - 켜기: <code id="uOn"></code><br/>
          - Antigravity 켜기: <code id="uAgy"></code><br/>
          - 끄기: <code id="uOff"></code><br/>
          - 절전: <code id="uSleep"></code>
        </div>
      </details>
    </div>
  </div>
  <script>
    const TOKEN_KEY = 'pc_relay_token';
    const ONECLICK_KEY = 'pc_relay_oneclick';
    let deferredInstallPrompt = null;
    if ('serviceWorker' in navigator) {{
      navigator.serviceWorker.register('/sw.js').catch(() => {{}});
    }}
    window.addEventListener('beforeinstallprompt', (e) => {{
      e.preventDefault();
      deferredInstallPrompt = e;
      document.getElementById('installCard').style.display = 'block';
    }});
    window.addEventListener('appinstalled', () => {{
      deferredInstallPrompt = null;
      document.getElementById('installCard').style.display = 'none';
      showToast('앱 설치가 완료되었습니다!', true);
    }});
    async function installPwa() {{
      if (!deferredInstallPrompt) return;
      deferredInstallPrompt.prompt();
      await deferredInstallPrompt.userChoice;
      deferredInstallPrompt = null;
      document.getElementById('installCard').style.display = 'none';
    }}
    (function init() {{
      const p = new URLSearchParams(location.search);
      if (p.get('token')) {{
        localStorage.setItem(TOKEN_KEY, p.get('token').trim());
        p.delete('token');
        history.replaceState({{}}, '', location.pathname + (p.toString() ? '?' + p.toString() : ''));
      }}
      document.getElementById('oneClickToggle').checked = localStorage.getItem(ONECLICK_KEY) === '1';
      document.getElementById('uOn').textContent = location.origin + '/api/pc/on';
      document.getElementById('uAgy').textContent = location.origin + '/api/pc/antigravity/start';
      document.getElementById('uOff').textContent = location.origin + '/api/pc/off';
      document.getElementById('uSleep').textContent = location.origin + '/api/pc/sleep';
    }})();
    function getToken() {{ return localStorage.getItem(TOKEN_KEY) || ''; }}
    function toggleTokenPanel(force) {{
      const c = document.getElementById('tokenCard');
      c.style.display = (force === true || c.style.display === 'none') ? 'block' : 'none';
    }}
    function saveToken() {{
      const v = document.getElementById('tokenInput').value.trim();
      if (!v) return;
      localStorage.setItem(TOKEN_KEY, v);
      document.getElementById('tokenInput').value = '';
      toggleTokenPanel(false);
      refreshStatus();
    }}
    function saveOneClickPref() {{
      localStorage.setItem(ONECLICK_KEY, document.getElementById('oneClickToggle').checked ? '1' : '0');
    }}
    function showToast(msg, ok) {{
      const t = document.getElementById('toast');
      t.textContent = msg;
      t.className = 'toast show ' + (ok ? 'ok' : 'err');
    }}
    async function refreshStatus() {{
      const b = document.getElementById('statusBadge');
      const m = document.getElementById('statusMeta');
      const token = getToken();
      if (!token) {{ toggleTokenPanel(true); b.textContent = '토큰 필요'; b.className = 'badge off'; return; }}
      try {{
        const r = await fetch('/api/pc/status', {{ headers: {{ 'X-Auth-Token': token }} }});
        if (r.status === 401 || r.status === 429) {{ toggleTokenPanel(true); b.textContent = '인증 실패'; b.className = 'badge off'; return; }}
        const d = await r.json();
        if (!r.ok || d.success === false) {{
          b.textContent = d.authError ? '⚠️ PC 인증 오류' : '⚠️ 백엔드 오류'; b.className = 'badge off';
          m.textContent = d.message || 'PC 백엔드 상태 조회에 실패했습니다.';
          return;
        }}
        if (d.online) {{
          b.textContent = '🟢 PC 켜짐'; b.className = 'badge';
          const agy = d.pc?.antigravityRunning
            ? '🟢 실행 중'
            : (d.pc?.userSessionActive ? '⚫ 꺼짐 (실행 가능)' : '🔒 꺼짐 (Windows 로그인 필요)');
          m.textContent = '가동 시간: ' + (d.pc?.uptimeText || '-') + '\\nAntigravity: ' + agy;
        }} else {{
          b.textContent = '⚫ PC 꺼짐'; b.className = 'badge off';
          m.textContent = 'PC 응답 없음 (꺼져 있거나 절전 상태). 위 [PC 켜기] 버튼으로 켤 수 있습니다.';
        }}
      }} catch (e) {{
        b.textContent = '중계기 연결 오류'; b.className = 'badge off';
      }}
    }}
    async function trigger(action, label) {{
      const token = getToken();
      if (!token) {{ toggleTokenPanel(true); return showToast('먼저 토큰을 저장하세요.', false); }}
      if (label && !document.getElementById('oneClickToggle').checked) {{
        if (!confirm('정말 ' + label + '할까요?')) return;
      }}
      const r = await fetch('/api/pc/' + action, {{ method: 'POST', headers: {{ 'X-Auth-Token': token }} }});
      const d = await r.json().catch(() => ({{ message: '응답 오류' }}));
      showToast(d.message || '요청 완료', r.ok && d.success !== false);
      if (action === 'on') setTimeout(refreshStatus, 5000);
      if (action === 'antigravity/start') setTimeout(refreshStatus, 2000);
    }}
    refreshStatus();
  </script>
</body>
</html>"""


class AuthLimiter:
    def __init__(self, token: str):
        self.token = token
        self.lock = threading.Lock()
        self.failures: dict[str, tuple[int, float, float]] = {}

    def check(self, ip: str, provided: str | None) -> tuple[bool, int, str]:
        now = time.time()
        with self.lock:
            count, win_start, blocked_until = self.failures.get(ip, (0, now, 0.0))
            if blocked_until > now:
                return False, 429, "인증 실패 횟수가 많아 잠시 차단되었습니다."

        if provided and hmac.compare_digest(provided, self.token):
            with self.lock:
                self.failures.pop(ip, None)
            return True, 200, ""

        with self.lock:
            count, win_start, blocked_until = self.failures.get(ip, (0, now, 0.0))
            if now - win_start > 60:
                count = 0
                win_start = now
            count += 1
            if count >= 10:
                blocked_until = now + 300
            self.failures[ip] = (count, win_start, blocked_until)

        return False, 401, "유효한 인증 토큰이 필요합니다."


def resolve_client_ip(peer_ip: str, headers) -> str:
    try:
        ip_obj = ipaddress.ip_address(peer_ip)
        is_loopback = ip_obj.is_loopback
    except ValueError:
        is_loopback = peer_ip in ("127.0.0.1", "::1")

    if is_loopback and headers is not None:
        cf_ip = (headers.get("CF-Connecting-IP") or "").strip()
        if cf_ip and len(cf_ip) <= 64:
            return cf_ip
        xff = (headers.get("X-Forwarded-For") or "").strip()
        if xff:
            first = xff.split(",")[0].strip()
            if first and len(first) <= 64:
                return first
    return peer_ip


def send_tunnel_url_notification(webhook_url: str, pc_name: str, public_url: str, pwa_link: str) -> None:
    url = (webhook_url or "").strip()
    if not url:
        return
    try:
        lower = url.lower()
        if "discord.com/api/webhooks/" in lower or "discordapp.com/api/webhooks/" in lower:
            payload = json.dumps(
                {
                    "content": (
                        f"⚡ **{pc_name} 원격 전원 중계기 연결 준비 완료 (VPN 불필요)**\n"
                        f"• 서버 주소: `{public_url}`\n"
                        f"• PWA 자동 설정 열기: {pwa_link}"
                    )
                },
                ensure_ascii=False,
            ).encode("utf-8")
            req = urllib.request.Request(
                url,
                data=payload,
                method="POST",
                headers={"Content-Type": "application/json", "User-Agent": "pc-remote-power-relay/1.0"},
            )
        else:
            # ntfy.sh 또는 일반 텍스트 웹훅 (HTTP 헤더는 ASCII만 허용)
            ascii_name = pc_name.encode("ascii", "ignore").decode("ascii").strip() or "PC"
            body = (
                f"{pc_name} 원격 전원 중계기가 시작되었습니다.\n"
                f"서버 주소: {public_url}\n"
                f"PWA 열기: {pwa_link}"
            ).encode("utf-8")
            req = urllib.request.Request(
                url,
                data=body,
                method="POST",
                headers={
                    "Title": f"{ascii_name} Remote Power",
                    "Click": pwa_link,
                    "Content-Type": "text/plain; charset=utf-8",
                },
            )
        with urllib.request.urlopen(req, timeout=8) as resp:
            print(f"[알림 전송 완료] HTTP {resp.status}")
    except Exception as e:
        print(f"[알림 전송 실패] {e}")


def publish_sync_url(
    sync_topic: str,
    public_url: str,
    pc_name: str,
    mode: str = "relay",
    sync_server: str = DEFAULT_SYNC_SERVER,
) -> bool:
    topic = (sync_topic or "").strip()
    url = (public_url or "").strip().rstrip("/")
    server = (sync_server or DEFAULT_SYNC_SERVER).strip().rstrip("/")
    if not topic or not url or not server:
        return False
    payload = json.dumps(
        {
            "serverUrl": url,
            "pcName": pc_name,
            "mode": mode,
            "ts": int(time.time()),
        },
        ensure_ascii=False,
    ).encode("utf-8")
    req = urllib.request.Request(
        f"{server}/{urllib.parse.quote(topic)}",
        data=payload,
        method="POST",
        headers={
            "Content-Type": "text/plain; charset=utf-8",
            "User-Agent": "pc-remote-power-sync/1.0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            return 200 <= resp.status < 300
    except Exception as e:
        print(f"[주소 자동 동기화 대기] {e}")
        return False


class CloudflareTunnelManager:
    def __init__(self, cfg: dict, relay_port: int):
        self.cfg = cfg
        self.relay_port = relay_port
        self.mode = (cfg.get("tunnel_mode") or "none").strip().lower()
        self.token = (cfg.get("cloudflare_tunnel_token") or "").strip()
        self.public_url = (cfg.get("public_url") or "").strip().rstrip("/")
        self.sync_topic = derive_sync_topic(cfg.get("relay_token", ""), cfg.get("sync_topic", ""))
        self.sync_server = (cfg.get("sync_server") or DEFAULT_SYNC_SERVER).strip().rstrip("/")
        self._stop = threading.Event()
        self._sync_event = threading.Event()
        self._proc: subprocess.Popen[str] | None = None
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self._sync_thread: threading.Thread | None = None
        self.running = False
        self.last_error = ""

    def snapshot(self) -> dict:
        with self._lock:
            return {
                "tunnelMode": self.mode,
                "tunnelRunning": self.running,
                "publicUrl": self.public_url,
                "syncTopic": self.sync_topic,
                "error": self.last_error,
            }

    def start(self) -> None:
        if self.mode not in ("quick", "token"):
            return
        if self.mode == "token" and not self.token:
            self.last_error = "cloudflare_tunnel_token이 비어 있어 Named Tunnel을 시작하지 않았습니다."
            print(f"[Cloudflare Tunnel 경고] {self.last_error}")
            return

        binary = find_cloudflared_binary()
        if not binary:
            self.last_error = "cloudflared가 설치되어 있지 않습니다."
            print("[Cloudflare Tunnel 안내] cloudflared를 찾지 못했습니다. 로컬 HTTP 서버만 실행합니다.")
            print("  - Termux(공기계): pkg update -y && pkg install -y cloudflared")
            print("  - 라즈베리파이/리눅스: bash relay/setup_relay_cloudflare.sh")
            print("  - Windows: winget install -e --id Cloudflare.cloudflared")
            return

        if self.sync_topic:
            self._sync_thread = threading.Thread(target=self._sync_loop, daemon=True)
            self._sync_thread.start()

        self._thread = threading.Thread(target=self._run_loop, args=(binary,), daemon=True)
        self._thread.start()

    def _sync_loop(self) -> None:
        retry_soon = False
        while not self._stop.is_set():
            wait_sec = 15 if retry_soon else SYNC_HEARTBEAT_SEC
            self._sync_event.wait(timeout=wait_sec)
            if self._stop.is_set():
                break
            self._sync_event.clear()
            with self._lock:
                url = self.public_url
            if not url or not self.sync_topic:
                retry_soon = False
                continue
            pc_name = self.cfg.get("pc_name", "My-PC")
            ok = publish_sync_url(self.sync_topic, url, pc_name, "relay", self.sync_server)
            if ok:
                print(f"[주소 자동 동기화 완료] 재부팅 후에도 스마트폰 PWA가 새 주소를 자동으로 찾아 연결합니다 ({self.sync_topic})")
                retry_soon = False
            else:
                retry_soon = True

    def _run_loop(self, binary: str) -> None:
        while not self._stop.is_set():
            if self.mode == "token":
                cmd = [binary, "tunnel", "--no-autoupdate", "run", "--token", self.token]
            else:
                cmd = [binary, "tunnel", "--no-autoupdate", "--url", f"http://127.0.0.1:{self.relay_port}"]

            try:
                proc = subprocess.Popen(
                    cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    bufsize=1,
                )
            except Exception as e:
                with self._lock:
                    self.running = False
                    self.last_error = str(e)
                print(f"[Cloudflare Tunnel 시작 실패] {e}")
                self._stop.wait(10)
                continue

            with self._lock:
                self._proc = proc
                self.running = True
                self.last_error = ""

            if self.mode == "token":
                print("[Cloudflare Tunnel] Named Tunnel 실행 중 (VPN·포트포워딩 불필요)")
                if self.public_url:
                    self._announce_url(self.public_url)
            else:
                print("[Cloudflare Tunnel] Quick Tunnel 무료 HTTPS 주소 발급 중...")

            assert proc.stdout is not None
            for line in proc.stdout:
                if self._stop.is_set():
                    break
                text = line.strip()
                if not text:
                    continue
                if self.mode == "quick":
                    match = TRYCLOUDFLARE_RE.search(text)
                    if match:
                        found_url = match.group(0).rstrip("/")
                        changed = False
                        with self._lock:
                            if found_url != self.public_url:
                                self.public_url = found_url
                                changed = True
                        if changed:
                            self._announce_url(found_url)
                if "ERR " in text or "failed to" in text.lower():
                    print(f"[cloudflared] {text}")

            rc = proc.wait()
            with self._lock:
                self._proc = None
                self.running = False

            if not self._stop.is_set():
                print(f"[Cloudflare Tunnel] 프로세스 종료(코드 {rc}) — 5초 후 자동 재연결합니다...")
                self._stop.wait(5)

    def _announce_url(self, url: str) -> None:
        pc_name = self.cfg.get("pc_name", "My-PC")
        pwa_link = build_pwa_setup_link(
            url,
            pc_name,
            self.cfg.get("pwa_base_url", DEFAULT_PWA_BASE_URL),
            self.sync_topic,
        )
        try:
            TUNNEL_URL_PATH.write_text(f"{url}\n{pwa_link}\n", encoding="utf-8")
        except Exception:
            pass

        print("")
        print("=" * 64)
        print("  🌐 VPN 없이 외부 접속 가능! (Cloudflare Tunnel HTTPS 활성)")
        print(f"  • 서버 주소       : {url}")
        print(f"  • PWA 자동 설정   : {pwa_link}")
        print("    (재부팅으로 주소가 바뀌어도 스마트폰 PWA가 새 주소를 자동 동기화합니다!)")
        print(f"  • 중계기 직접 접속: {url}/?token={self.cfg['relay_token']}")
        print("=" * 64)
        print("")

        self._sync_event.set()

        webhook = (self.cfg.get("notify_webhook_url") or "").strip()
        if webhook:
            threading.Thread(
                target=send_tunnel_url_notification,
                args=(webhook, pc_name, url, pwa_link),
                daemon=True,
            ).start()

    def stop(self) -> None:
        self._stop.set()
        self._sync_event.set()
        with self._lock:
            proc = self._proc
        if proc and proc.poll() is None:
            try:
                proc.terminate()
                proc.wait(timeout=4)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass


def make_handler(cfg: dict, limiter: AuthLimiter, tunnel_manager: CloudflareTunnelManager | None = None):
    html_bytes = build_html(cfg).encode("utf-8")
    sw_bytes = SERVICE_WORKER_JS.encode("utf-8")
    icon_192 = load_icon_bytes("icon-192.png")
    icon_512 = load_icon_bytes("icon-512.png")
    svg_bytes = ICON_SVG.encode("utf-8")

    manifest_icons = []
    if icon_192:
        manifest_icons.append({"src": "/icon-192.png", "sizes": "192x192", "type": "image/png", "purpose": "any"})
    if icon_512:
        manifest_icons.append({"src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any"})
    if not manifest_icons:
        manifest_icons.append({"src": "/icon.svg", "sizes": "any", "type": "image/svg+xml"})

    manifest_bytes = json.dumps(
        {
            "id": "/",
            "name": f"{cfg['pc_name']} 통합 전원",
            "short_name": "PC 전원",
            "start_url": "/",
            "scope": "/",
            "display": "standalone",
            "background_color": "#0b1120",
            "theme_color": "#0b1120",
            "icons": manifest_icons,
        },
        ensure_ascii=False,
    ).encode("utf-8")

    class Handler(http.server.BaseHTTPRequestHandler):
        def _client_ip(self) -> str:
            return resolve_client_ip(self.client_address[0], self.headers)

        def log_message(self, format: str, *args) -> None:
            print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {self._client_ip()} - {format % args}")

        def _extract_token(self) -> str | None:
            hdr = self.headers.get("X-Auth-Token")
            if hdr:
                return hdr.strip()
            auth = self.headers.get("Authorization", "")
            if auth.lower().startswith("bearer "):
                return auth[7:].strip()
            qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if "token" in qs and qs["token"]:
                return qs["token"][0].strip()
            return None

        def _send_cors_headers(self) -> None:
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Auth-Token, Authorization")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Private-Network", "true")
            self.send_header("Access-Control-Max-Age", "86400")

        def _drain_body(self) -> None:
            raw_len = self.headers.get("Content-Length")
            if not raw_len:
                return
            try:
                length = int(raw_len)
            except ValueError:
                return
            if length > 0:
                self.rfile.read(min(length, 65536))

        def _send_bytes(self, code: int, content_type: str, data: bytes) -> None:
            self.send_response(code)
            self._send_cors_headers()
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_OPTIONS(self) -> None:
            self.send_response(204)
            self._send_cors_headers()
            self.send_header("Content-Length", "0")
            self.end_headers()

        def _send_json(self, code: int, obj: dict) -> None:
            self._send_bytes(code, "application/json; charset=utf-8", json.dumps(obj, ensure_ascii=False).encode("utf-8"))

        def _require_auth(self) -> bool:
            ok, code, msg = limiter.check(self._client_ip(), self._extract_token())
            if not ok:
                self._send_json(code, {"success": False, "message": msg})
                return False
            return True

        def do_GET(self) -> None:
            route = urllib.parse.urlparse(self.path).path
            if route == "/":
                self._send_bytes(200, "text/html; charset=utf-8", html_bytes)
            elif route == "/manifest.webmanifest":
                self._send_bytes(200, "application/manifest+json; charset=utf-8", manifest_bytes)
            elif route == "/sw.js":
                self._send_bytes(200, "application/javascript; charset=utf-8", sw_bytes)
            elif route == "/icon-192.png":
                if icon_192:
                    self._send_bytes(200, "image/png", icon_192)
                else:
                    self._send_bytes(200, "image/svg+xml; charset=utf-8", svg_bytes)
            elif route == "/icon-512.png":
                if icon_512:
                    self._send_bytes(200, "image/png", icon_512)
                else:
                    self._send_bytes(200, "image/svg+xml; charset=utf-8", svg_bytes)
            elif route == "/icon.svg":
                self._send_bytes(200, "image/svg+xml; charset=utf-8", svg_bytes)
            elif route == "/api/health":
                self._send_json(200, {"ok": True})
            elif route == "/api/pc/status":
                if not self._require_auth():
                    return
                relay_meta = tunnel_manager.snapshot() if tunnel_manager else {"tunnelMode": cfg.get("tunnel_mode", "none")}
                code, data = call_pc_web(cfg, "GET", "/api/status", timeout=2.5)
                if code == 200:
                    self._send_json(200, {"success": True, "online": True, "pc": data, "relay": relay_meta})
                elif code in (401, 429):
                    self._send_json(
                        502,
                        {
                            "success": False,
                            "online": False,
                            "authError": True,
                            "relay": relay_meta,
                            "message": f"중계기 ↔ PC 인증 오류(HTTP {code}): relay-config.json의 pc_web_token과 PC의 web-config.json ApiToken이 일치하는지 확인하세요.",
                        },
                    )
                else:
                    self._send_json(200, {"success": True, "online": False, "pc": None, "relay": relay_meta})
            else:
                self._send_json(404, {"success": False, "message": "Not Found"})

        def do_POST(self) -> None:
            self._drain_body()
            route = urllib.parse.urlparse(self.path).path
            if not route.startswith("/api/pc/"):
                self._send_json(404, {"success": False, "message": "Not Found"})
                return
            if not self._require_auth():
                return

            action = route[len("/api/pc/"):].strip("/").lower()
            if action == "on":
                try:
                    send_magic_packet(cfg["pc_mac"], cfg["broadcast_ip"])
                    self._send_json(200, {"success": True, "message": f"매직 패킷을 전송했습니다 ({cfg['pc_mac']}). 잠시 후 PC가 켜집니다."})
                except Exception as e:
                    self._send_json(500, {"success": False, "message": f"WoL 전송 실패: {e}"})
            elif action == "antigravity/start":
                code, data = call_pc_web(cfg, "POST", "/api/app/antigravity/start", timeout=15.0)
                self._send_json(code, data)
            elif action in ("off", "shutdown", "sleep", "reboot", "cancel"):
                target_action = "shutdown" if action == "off" else action
                code, data = call_pc_web(cfg, "POST", f"/api/power/{target_action}", timeout=3.0)
                self._send_json(code, data)
            else:
                self._send_json(400, {"success": False, "message": f"지원하지 않는 명령입니다: {action}"})

    return Handler


def duckdns_loop(cfg: dict) -> None:
    domain = (cfg.get("duckdns_domain") or "").replace(".duckdns.org", "").strip()
    token = (cfg.get("duckdns_token") or "").strip()
    if not domain or not token:
        return
    while True:
        try:
            url = f"https://www.duckdns.org/update?domains={urllib.parse.quote(domain)}&token={urllib.parse.quote(token)}&ip="
            with urllib.request.urlopen(url, timeout=10) as resp:
                print(f"[DuckDNS] {domain}.duckdns.org -> {resp.read().decode('utf-8', errors='replace').strip()}")
        except Exception as e:
            print(f"[DuckDNS 오류] {e}")
        time.sleep(300)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="PC 원격 전원 중계기 (WoL + OFF + VPN 없는 Cloudflare Tunnel)")
    parser.add_argument("--setup", "--reconfigure", dest="setup", action="store_true", help="relay-config.json 설정 마법사를 다시 실행")
    parser.add_argument("--setup-only", dest="setup_only", action="store_true", help="relay-config.json만 생성/수정하고 종료")
    parser.add_argument("--tunnel", choices=("quick", "token", "none"), default=None, help="실행 시 Cloudflare Tunnel 모드 덮어쓰기")
    parser.add_argument("--no-tunnel", action="store_true", help="Cloudflare Tunnel을 실행하지 않고 로컬 HTTP만 구동")
    return parser.parse_args()


class ReusableThreadingHTTPServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True


def main() -> None:
    args = parse_args()
    cfg = ensure_config(force_setup=(args.setup or args.setup_only))
    if args.setup_only:
        return
    if args.no_tunnel:
        cfg = dict(cfg)
        cfg["tunnel_mode"] = "none"
    elif args.tunnel:
        cfg = dict(cfg)
        cfg["tunnel_mode"] = args.tunnel
        if CONFIG_PATH.exists():
            try:
                with CONFIG_PATH.open("w", encoding="utf-8") as wf:
                    json.dump(cfg, wf, ensure_ascii=False, indent=2)
            except Exception:
                pass

    if cfg.get("duckdns_domain") and cfg.get("duckdns_token"):
        threading.Thread(target=duckdns_loop, args=(cfg,), daemon=True).start()

    port = int(cfg.get("relay_port", 18090))
    tunnel = CloudflareTunnelManager(cfg, port)
    server = ReusableThreadingHTTPServer(("0.0.0.0", port), make_handler(cfg, AuthLimiter(cfg["relay_token"]), tunnel))
    print(f"통합 원격 전원 중계기 실행 중: http://0.0.0.0:{port}/?token={cfg['relay_token']}")
    tunnel.start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n중계 서버를 종료합니다.")
    finally:
        tunnel.stop()
        server.server_close()


if __name__ == "__main__":
    main()
