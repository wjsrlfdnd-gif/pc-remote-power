# 상시 구동 기기용 통합 ON/OFF 중계 서버 (VPN 없는 Cloudflare Tunnel 내장)

집에 항상 켜둘 수 있는 **안드로이드 공기계(Termux)**, **라즈베리파이**, 또는 **리눅스/미니PC**에서 `wol_relay.py`를 실행하면, **VPN이나 공유기 포트포워딩 없이** 폰 한 화면(PWA 앱)에서 **PC 켜기(WoL) + 끄기(OFF) + 절전 + 재부팅 + Antigravity 켜기**를 모두 원클릭으로 사용할 수 있습니다.

---

## 1. 먼저 Windows PC 준비
1. 저장소 전체를 내려받은 뒤(ZIP은 반드시 **모두 추출**) 순서대로 실행:
   - `0_앱_빌드_및_설치.bat`
   - `1_Windows_WOL_설정(관리자).bat`
   - `2_폰_원클릭_웹_설정.bat` *(표시되는 PC 내부 IP와 `ApiToken` 메모)*
   - `3_웹_자동실행_방화벽_등록(관리자).bat`

---

## 2. 상시 기기에서 중계기 + Cloudflare Tunnel 원클릭 실행

### 방법 A: 안드로이드 공기계 (Termux)
1. **GitHub**(`termux/termux-app`) 또는 **F-Droid**에서 `Termux` 설치 *(재부팅 자동 실행이 필요하면 같은 출처의 `Termux:Boot`도 설치)*
2. Termux 실행 후 저장소 클론 및 원클릭 실행:
   ```bash
   pkg update -y && pkg install -y git
   git clone https://github.com/wjsrlfdnd-gif/pc-remote-power.git
   cd pc-remote-power
   bash relay/setup_relay_cloudflare.sh
   ```
   - `python`, `cloudflared`가 자동 설치되고 `termux-wake-lock`이 적용됩니다.
   - 재부팅 시 자동 실행 등록(선택):
     ```bash
     bash relay/setup_relay_cloudflare.sh --install-boot
     ```

### 방법 B: 라즈베리파이 / 리눅스 미니PC
```bash
git clone https://github.com/wjsrlfdnd-gif/pc-remote-power.git
cd pc-remote-power
bash relay/setup_relay_cloudflare.sh
```
- `cloudflared`가 없으면 CPU 아키텍처(`arm64`/`arm`/`amd64`)에 맞게 `~/.local/bin/cloudflared`로 자동 설치됩니다.
- 부팅 시 자동 실행(systemd 서비스) 등록:
  ```bash
  bash relay/setup_relay_cloudflare.sh --install-systemd
  ```

---

## 3. Cloudflare Tunnel 두 가지 모드 안내 (모두 VPN·포트포워딩 불필요)

첫 실행 시 설정 마법사에서 원하는 방식을 선택할 수 있습니다. (나중에 다시 설정하려면 `python3 relay/wol_relay.py --setup`)

### ① Quick Tunnel (`quick`) — 계정·도메인 0원, 1분 시작
- 별도 가입 없이 즉시 `https://xxxx.trycloudflare.com` 무료 HTTPS 주소가 생성됩니다.
- 터미널에 출력되는 **PWA 자동 설정 링크**를 스마트폰에서 열고 `relay_token`만 한 번 입력하면 바로 사용 가능합니다.
- **재부팅 후 새 주소 자동 수신 팁**: 설정 시 **알림 웹훅 URL**에 Discord 웹훅 또는 무료 `https://ntfy.sh/<나만의비밀토픽>`을 넣어 두면, 중계기가 재시작되어 새 주소가 발급될 때마다 스마트폰으로 클릭 가능한 PWA 링크를 자동 푸시합니다.

### ② Named Tunnel (`token`) — 영구 고정 HTTPS 주소 (상시 운영 추천)
1. [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) (무료 플랜) → **Networks → Tunnels → Create a tunnel → Cloudflared**
2. 발급된 커넥터 토큰(`eyJh...`) 복사
3. **Public Hostname** 탭에서 원하는 서브도메인(예: `pc.mydomain.com`)을 `HTTP` → `127.0.0.1:18090`으로 연결
4. 중계기 설정 마법사에서 **`2) token`** 선택 후 토큰과 고정 주소 입력
   → 기기가 재부팅되어도 주소가 절대 바뀌지 않습니다!

---

## 4. 유용한 실행 옵션
```bash
python3 relay/wol_relay.py --setup           # 설정 마법사 다시 실행
python3 relay/wol_relay.py --tunnel quick    # 이번 실행만 Quick Tunnel 강제 사용
python3 relay/wol_relay.py --no-tunnel       # 터널 없이 집 내부망 HTTP만 실행
```
- 최신 발급 주소는 `relay/tunnel-url.txt`에도 자동 저장됩니다.
