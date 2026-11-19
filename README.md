# ⚡ PC 원격 전원 관리 (VPN 없는 Cloudflare Tunnel + PWA)

스마트폰과 데스크톱 브라우저에서 **홈 화면 앱(PWA)**으로 설치하여 **VPN(Tailscale)이나 공유기 포트포워딩 없이** 집 PC의 **부팅(Wake-on-LAN)**, **Antigravity 실행**, **절전**, **재부팅**, **종료**를 원격 제어할 수 있는 통합 저장소입니다.

```text
[스마트폰 PWA (LTE/5G, VPN 불필요)]
        │  HTTPS (Cloudflare Tunnel)
        ▼
[집 안 상시 중계기 (공기계 Termux / 라즈베리파이 / 리눅스)]
  relay/wol_relay.py + cloudflared 내장 실행
        │  집 내부망 WoL(매직 패킷) + HTTP API
        ▼
[집 Windows PC]
  RemotePowerWeb (부팅 시 자동 실행)
```

> **보안 안내**: 이 저장소에는 개인 서버 주소, 인증 토큰(`X-Auth-Token`), 터널 토큰, MAC 주소 등 민감 정보가 전혀 포함되지 않습니다. `.gitignore`가 `web-config.json`, `tunnel-config.json`, `config.json`, `relay-config.json` 및 빌드 산출물을 자동 제외합니다.

---

## 📁 저장소 구성

### 1. 프론트엔드 정적 PWA (GitHub Pages 호스팅)
- `index.html`: 모바일·데스크톱 대응 원격 전원 관리 PWA 본체 (`localStorage` 연결 설정 지원)
- `manifest.webmanifest`, `sw.js`, `icon-192.png`, `icon-512.png`, `icon.svg`, `.nojekyll`: 정식 홈 화면 앱 설치(PWA) 지원

### 2. 집 안 상시 중계기 + Cloudflare Tunnel (WoL 켜기 + 끄기 통합, VPN 불필요)
- `relay/wol_relay.py`: 안드로이드 공기계(Termux) / 라즈베리파이 / 리눅스용 통합 ON/OFF 중계 서버 (**Cloudflare Tunnel 자동 실행 내장**)
- `relay/setup_relay_cloudflare.sh`: `python` + `cloudflared` 자동 설치 및 실행/부팅 등록 원클릭 스크립트
- 상세 가이드: [`relay/README_중계기.md`](relay/README_중계기.md)

### 3. Windows PC 백엔드 & 원클릭 설치 스크립트
- `PowerCore/`, `RemotePowerWeb/`: Windows 부팅 시 자동 실행되는 원클릭 웹/API 서버 (`CORS`, `PNA`, `CF-Connecting-IP` 지원)
- `0_앱_빌드_및_설치.bat` ~ `4_Cloudflare_터널_외부접속_설정(관리자).bat`: Windows PC 원클릭 설치·설정 스크립트
- `optional_디스코드_봇_설정.bat`, `optional_Tailscale_원격데스크톱_설정(관리자).bat`: 선택 기능

---

## 🚀 설치 및 실행 순서 (VPN 없이 사용하기)

> ⚠️ **GitHub에서 ZIP으로 내려받은 경우**: 반드시 **`pc-remote-power-main.zip` 우클릭 → 모두 추출(압축 풀기)** 로 일반 폴더에 전체 압축을 푼 뒤, `scripts` 폴더가 함께 있는 위치에서 `.bat` 파일을 실행하세요. (ZIP 창 안에서 바로 더블클릭하면 `scripts` 폴더를 찾지 못해 오류가 발생합니다.)

### 1단계. Windows PC 준비 (필수)
저장소 폴더 안에서 아래 순서대로 실행합니다.

1. **`0_앱_빌드_및_설치.bat`**: .NET 9 SDK 확인 및 `RemotePowerWeb.exe` 빌드
2. **`1_Windows_WOL_설정(관리자).bat`**: 유선 랜 WoL 활성화 및 Windows 빠른 시작(`HiberbootEnabled`) 해제
3. **`2_폰_원클릭_웹_설정.bat`**: 포트(`18080`) 및 랜덤 `ApiToken` 생성 (`web-config.json`) — 표시되는 **PC 내부 IP**와 **`ApiToken`**을 메모해 두세요.
4. **`3_웹_자동실행_방화벽_등록(관리자).bat`**: 방화벽 개방, 부팅 자동 실행(`PCRemotePowerWeb`) 및 `LaunchAntigravityForUser` 등록

### 2단계. VPN 없이 외부 HTTPS 연결하기 (사용 환경에 따라 택 1)

#### ✅ 방법 A: 상시 중계기(공기계/라즈베리파이) + PC 함께 사용 *(WoL 켜기 포함 — 권장)*
집 안 공기계(Termux) 또는 라즈베리파이/리눅스에서 저장소를 받은 뒤 아래 1줄만 실행하세요:
```bash
bash relay/setup_relay_cloudflare.sh
```
1. `python`과 `cloudflared`가 자동으로 설치되고 설정 마법사가 열립니다.
2. 1단계에서 확인한 PC의 **MAC 주소**, **내부 IP**, **`ApiToken`**을 입력합니다.
3. 외부 접속 방식 선택:
   - **`1) quick` (가장 빠름, 계정·도메인 불필요)**: 즉시 `https://xxxx.trycloudflare.com` 무료 HTTPS 주소가 발급됩니다. *(재부팅 시 새 주소를 폰으로 자동 받으려면 Discord Webhook 또는 `https://ntfy.sh/<나만의비밀토픽>` 입력 가능)*
   - **`2) token` (상시 영구 고정 주소 추천)**: 무료 Cloudflare Zero Trust 대시보드에서 터널을 생성해 받은 토큰(`eyJh...`)을 입력하면 재부팅해도 영구 고정 HTTPS 주소(`https://pc.mydomain.com`)가 유지됩니다.
4. 터미널에 출력되는 **PWA 자동 설정 링크**를 스마트폰에서 열고, 토큰을 1회 저장하면 끝! (VPN 전혀 필요 없음)

#### ✅ 방법 B: 중계기 없이 Windows PC만 단독 사용 *(켜진 PC 제어)*
Windows PC에서 **`4_Cloudflare_터널_외부접속_설정(관리자).bat`** 을 실행하면 `cloudflared` 자동 설치부터 부팅 시 자동 실행(`PCRemotePowerTunnel`) 등록까지 한 번에 완료됩니다.

---

## 📱 스마트폰 앱(PWA) 설치
1. 배포된 PWA 주소(`https://<계정명>.github.io/<저장소명>/`) 또는 터미널에 출력된 **PWA 자동 설정 링크**로 접속합니다.
2. **📲 앱 설치**(Android Chrome) 또는 **공유 → 홈 화면에 추가**(iOS Safari)를 눌러 홈 화면에 앱으로 설치합니다.
3. LTE/5G 어디서든 **VPN을 켤 필요 없이** 바로 PC 전원 및 Antigravity를 제어할 수 있습니다.
