# ⚡ PC 원격 전원 관리 (PWA + Windows 백엔드)

스마트폰과 데스크톱 브라우저에서 **홈 화면 앱(PWA)**으로 설치하여 집 PC의 **부팅(Wake-on-LAN)**, **Antigravity 실행**, **절전**, **재부팅**, **종료**를 원격 제어할 수 있는 통합 저장소입니다.

> **보안 안내**: 이 저장소에는 개인 서버 주소, 인증 토큰(`X-Auth-Token`), MAC 주소 등 민감 정보가 전혀 포함되지 않습니다. `.gitignore`가 `web-config.json`, `config.json`, `relay-config.json` 및 빌드 산출물을 자동 제외합니다.

---

## 📁 저장소 구성

### 1. 프론트엔드 정적 PWA (GitHub Pages 호스팅 지원)
- `index.html`: 모바일·데스크톱 대응 원격 전원 관리 PWA 본체 (`localStorage` 연결 설정 지원)
- `manifest.webmanifest`, `sw.js`, `icon-192.png`, `icon-512.png`, `icon.svg`, `.nojekyll`: 정식 홈 화면 앱 설치(PWA) 지원

### 2. PC / 중계기 백엔드 (CORS & PWA 내장)
- `PowerCore/`, `RemotePowerWeb/`: Windows 부팅 시 자동 실행되는 원클릭 웹/API 서버 (`CORS` + `OPTIONS` 프리플라이트 지원)
- `relay/wol_relay.py`: 집 안 상시 기기(안드로이드 공기계 Termux / 라즈베리파이)용 통합 ON/OFF + 로컬 WoL 중계 서버
- `RemotePowerBot/`: 선택형 Discord 봇
- `0_앱_빌드_및_설치.bat` ~ `4_Tailscale_원격데스크톱_설정(관리자).bat`: 다른 PC에서 받아 바로 빌드·설치하는 원클릭 스크립트

---

## 🚀 다른 PC에서 받아 바로 설치하기

저장소를 `git clone`하거나 **Code → Download ZIP**으로 내려받은 폴더에서 순서대로 실행하세요.

1. **`0_앱_빌드_및_설치.bat`**: .NET 9 SDK 확인 및 `RemotePowerWeb.exe` / `RemotePowerBot.exe` 빌드
2. **`1_Windows_WOL_설정(관리자).bat`**: 유선 랜 WoL 활성화 및 Windows 빠른 시작(`HiberbootEnabled`) 해제
3. **`2_폰_원클릭_웹_설정.bat`**: 포트(`18080`) 및 랜덤 `ApiToken` 생성 (`web-config.json`)
4. **`3_웹_자동실행_방화벽_등록(관리자).bat`**: 방화벽 개방, 부팅 자동 실행(`PCRemotePowerWeb`) 및 `LaunchAntigravityForUser` 등록
5. **`4_Tailscale_원격데스크톱_설정(관리자).bat`** *(선택)*: Tailscale + Windows App(RDP) 자동 구성

---

## 🌐 GitHub Pages에 올려 스마트폰 앱처럼 설치하기

1. GitHub에서 새 저장소를 생성한 뒤 로컬 저장소(`D:\GitHub\pc-remote-power`)와 연결해 푸시합니다:
   ```bash
   git remote add origin <당신의-GitHub-저장소-URL>
   git push -u origin main
   ```
2. GitHub 저장소 **Settings → Pages** → Source `Deploy from a branch`, Branch `main` / `(root)` → **Save**
3. 잠시 후 생성되는 `https://<계정명>.github.io/<저장소명>/` 주소로 접속해 **📲 앱 설치**(Android Chrome) 또는 **공유 → 홈 화면에 추가**(iOS Safari)를 누릅니다.

### ⚠️ GitHub Pages(`https://`)에서 백엔드 연결 시 참고
- `https://` 페이지에서는 일반 `http://` 사설 IP 요청이 브라우저 Mixed Content 정책으로 차단됩니다.
- PC 또는 공기계에서 **`tailscale serve`** 를 실행하면 별도 도메인 없이 안전한 `https://...ts.net` 주소를 바로 연결할 수 있습니다:
  ```bash
  tailscale serve 18080   # PC RemotePowerWeb 직접 연결 시
  # 또는 공기계 중계기 사용 시: tailscale serve 18090
  ```
- 백엔드(`RemotePowerWeb`, `wol_relay.py`)에는 이미 `CORS` 허용 및 `OPTIONS` 프리플라이트 응답이 내장되어 있습니다.
