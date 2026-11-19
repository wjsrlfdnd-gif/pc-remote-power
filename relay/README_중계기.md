# 상시 구동 기기용 통합 ON/OFF 중계 서버 사용법

집에 항상 켜둘 수 있는 **안드로이드 공기계(Termux)**, **라즈베리파이**, 또는 **리눅스/미니PC**에서 `wol_relay.py`를 실행하면, 공유기 로그인이나 ARP 만료 걱정 없이 **폰 한 화면(PWA 앱)에서 PC 켜기(ON) + 끄기(OFF) + 절전 + Antigravity 켜기**를 모두 원클릭으로 사용할 수 있습니다.

---

## 1. 먼저 Windows PC 준비
1. `0_앱_빌드_및_설치.bat` 실행 (앱 빌드)
2. `2_폰_원클릭_웹_설정.bat` 실행 (포트 및 `ApiToken` 확인)
3. `3_웹_자동실행_방화벽_등록(관리자).bat` 실행

---

## 2. 상시 기기에서 `wol_relay.py` 실행

### 방법 A: 안드로이드 공기계 (Termux 사용)
1. **GitHub**(`termux/termux-app`) 또는 **F-Droid**에서 `Termux` 설치 (재부팅 자동 실행이 필요하면 같은 출처의 `Termux:Boot`도 설치)
2. Termux 실행 후:
   ```bash
   pkg update -y && pkg install -y python
   termux-wake-lock
   ```
3. 이 저장소의 `relay/wol_relay.py`와 루트의 `icon-192.png`, `icon-512.png`를 복사한 뒤 실행:
   ```bash
   python wol_relay.py
   ```
4. 첫 실행 시 안내에 따라 대상 PC의 MAC, 내부 IP, `ApiToken`을 입력하면 `relay-config.json`이 생성됩니다.

### 방법 B: 라즈베리파이 / 리눅스 미니PC
```bash
python3 wol_relay.py
```

---

## 3. 외부 접속 & 모바일 PWA "앱 설치"
- **외부 연결(택 1)**:
  - **공유기 포트포워딩**: `TCP 18090` → `(상시 기기 내부 IP):18090`
  - **Tailscale(권장)**: 상시 기기와 메인 폰에 Tailscale 설치 + `tailscale serve --bg 18090` 실행 시 백그라운드 상시 **HTTPS 주소**(`tailscale serve status`로 확인)가 발급되어 Android Chrome에서도 **정식 PWA "홈 화면에 앱 설치"** 버튼이 바로 동작합니다.
- **iOS Safari**: `공유 → 홈 화면에 추가`로 정식 아이콘 앱처럼 추가됩니다.
