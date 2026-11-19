#!/usr/bin/env bash
set -euo pipefail

# 집 안 상시 중계기(안드로이드 공기계 Termux / 라즈베리파이 / 리눅스)용
# VPN·포트포워딩 없는 Cloudflare Tunnel + WoL 중계 서버 원클릭 설치 및 실행 스크립트

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELAY_SCRIPT="$SCRIPT_DIR/wol_relay.py"

if [ ! -f "$RELAY_SCRIPT" ]; then
  echo "[오류] $RELAY_SCRIPT 파일을 찾을 수 없습니다."
  exit 1
fi

is_termux() {
  [ -n "${TERMUX_VERSION:-}" ] || [ -d "/data/data/com.termux/files/usr" ]
}

install_deps_termux() {
  echo "[Termux 감지] python 및 cloudflared 설치 여부를 확인합니다..."
  if ! command -v python >/dev/null 2>&1 || ! command -v cloudflared >/dev/null 2>&1; then
    pkg update -y
    pkg install -y python cloudflared
  fi
  if command -v termux-wake-lock >/dev/null 2>&1; then
    termux-wake-lock || true
  fi
}

install_cloudflared_linux() {
  if command -v cloudflared >/dev/null 2>&1 || [ -x "$HOME/.local/bin/cloudflared" ]; then
    export PATH="$HOME/.local/bin:$PATH"
    return 0
  fi

  local arch_raw arch_tag url target_dir target_bin
  arch_raw="$(uname -m)"
  case "$arch_raw" in
    x86_64|amd64) arch_tag="amd64" ;;
    aarch64|arm64) arch_tag="arm64" ;;
    armv7l|armv6l|armhf) arch_tag="arm" ;;
    *)
      echo "[경고] 알 수 없는 CPU 아키텍처($arch_raw)입니다. cloudflared를 직접 설치해 주세요."
      return 1
      ;;
  esac

  target_dir="$HOME/.local/bin"
  target_bin="$target_dir/cloudflared"
  mkdir -p "$target_dir"
  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch_tag}"
  echo "[설치] cloudflared 다운로드 중 ($arch_tag): $url"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$target_bin"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$target_bin" "$url"
  else
    echo "[오류] curl 또는 wget이 필요합니다."
    return 1
  fi

  chmod +x "$target_bin"
  export PATH="$target_dir:$PATH"
  echo "[설치 완료] $target_bin"
}

install_termux_boot() {
  local boot_dir="$HOME/.termux/boot"
  local boot_file="$boot_dir/start-pc-remote-relay.sh"
  mkdir -p "$boot_dir"
  cat > "$boot_file" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
cd "$SCRIPT_DIR"
nohup python "$RELAY_SCRIPT" > "$SCRIPT_DIR/relay.log" 2>&1 &
EOF
  chmod +x "$boot_file"
  echo "[자동 실행 등록 완료] $boot_file (Termux:Boot 앱이 설치되어 있으면 부팅 시 자동 시작됩니다.)"
}

install_systemd_service() {
  local service_file="/etc/systemd/system/pc-remote-relay.service"
  local py_bin cf_dir
  py_bin="$(command -v python3)"
  cf_dir="$(dirname "$(command -v cloudflared || echo "$HOME/.local/bin/cloudflared")")"
  if [ "$(id -u)" -ne 0 ]; then
    echo "[안내] systemd 서비스 등록에는 sudo 권한이 필요합니다."
    sudo tee "$service_file" >/dev/null <<EOF
[Unit]
Description=PC Remote Power WoL Relay + Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$SCRIPT_DIR
Environment=PATH=$cf_dir:/usr/local/bin:/usr/bin:/bin
ExecStart="$py_bin" "$RELAY_SCRIPT"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now pc-remote-relay.service
  else
    tee "$service_file" >/dev/null <<EOF
[Unit]
Description=PC Remote Power WoL Relay + Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SUDO_USER:-root}
WorkingDirectory=$SCRIPT_DIR
Environment=PATH=$cf_dir:/usr/local/bin:/usr/bin:/bin
ExecStart="$py_bin" "$RELAY_SCRIPT"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now pc-remote-relay.service
  fi
  echo "[systemd 등록 완료] 상태 확인: systemctl status pc-remote-relay"
}

ACTION="run"
PASS_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --install-boot) ACTION="boot" ;;
    --install-systemd) ACTION="systemd" ;;
    *) PASS_ARGS+=("$arg") ;;
  esac
done

if is_termux; then
  install_deps_termux
  PYTHON_BIN="python"
else
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[오류] python3가 설치되어 있지 않습니다. 먼저 python3를 설치해 주세요."
    exit 1
  fi
  install_cloudflared_linux || true
  PYTHON_BIN="python3"
fi

if [ "$ACTION" = "boot" ]; then
  if [ ! -f "$SCRIPT_DIR/relay-config.json" ]; then
    echo "[안내] 먼저 초기 설정을 진행한 뒤 Termux:Boot 자동 실행을 등록합니다."
    "$PYTHON_BIN" "$RELAY_SCRIPT" --setup-only
  fi
  install_termux_boot
  exit 0
fi

if [ "$ACTION" = "systemd" ]; then
  if [ ! -f "$SCRIPT_DIR/relay-config.json" ]; then
    echo "[안내] 먼저 초기 설정을 진행한 뒤 systemd 서비스를 등록합니다."
    "$PYTHON_BIN" "$RELAY_SCRIPT" --setup-only
  fi
  install_systemd_service
  exit 0
fi

if is_termux; then
  install_termux_boot || true
fi

pkill -f wol_relay.py 2>/dev/null || true
sleep 1

echo "=== VPN 없는 PC 원격 전원 중계기(Cloudflare Tunnel) 시작 ==="
if [ "${#PASS_ARGS[@]}" -gt 0 ]; then
  exec "$PYTHON_BIN" "$RELAY_SCRIPT" "${PASS_ARGS[@]}"
else
  exec "$PYTHON_BIN" "$RELAY_SCRIPT"
fi
