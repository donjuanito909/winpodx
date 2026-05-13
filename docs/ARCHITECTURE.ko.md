# 아키텍처

[English](ARCHITECTURE.md) | **한국어**

winpodx 가 어떻게 조립되어 있는지: 앱 실행 시 데이터 흐름, 기술 스택, 소스 트리 레이아웃.

## 동작 방식

```
                     ┌─────────────────────────────┐
  앱 메뉴에서         │     Linux Desktop (KDE,     │
  "Word" 클릭   ───>  │     GNOME, Sway, ...)       │
                     └──────────────┬──────────────┘
                                    │
                     ┌──────────────▼──────────────┐
                     │         winpodx             │
                     │  ┌─────────────────────┐    │
                     │  │ 자동 프로비저닝:    │    │
                     │  │  config → password  │    │
                     │  │  → container → RDP  │    │
                     │  │  → desktop entries  │    │
                     │  └─────────────────────┘    │
                     └──────────────┬──────────────┘
                                    │ FreeRDP RemoteApp
                     ┌──────────────▼──────────────┐
                     │   Windows Container (Podman)│
                     │   ┌──────────────────────┐  │
                     │   │  Word  Excel  PPT ...│  │
                     │   │ multi-session/rdprrap│  │
                     │   └──────────────────────┘  │
                     │   127.0.0.1:3390 (TLS)      │
                     └─────────────────────────────┘
```

Pod 의 명령 채널은 게스트 안에서 `127.0.0.1:8765` 에 listen 하는 bearer-auth HTTP agent (loopback 전용). RDP 자체는 `127.0.0.1:3390` 에서 TLS 암호화로 동작. Reverse-open (Linux 앱이 Windows "Open with..." 메뉴에 노출되는 기능) 은 별도의 호스트 측 listener daemon 이 `\\tsclient\home` 공유를 통해 요청을 받음.

## 기술 스택

| 레이어 | 기술 |
|-------|------|
| 언어 | Python 3.9+ (3.11+ 는 stdlib 만; 3.9/3.10 은 `tomli` 폴백) |
| CLI | argparse (stdlib) |
| GUI (선택) | PySide6 (Qt6) |
| 설정 | TOML (3.11+ 는 stdlib `tomllib` / 3.9/3.10 은 `tomli`; 자체 writer) |
| RDP | FreeRDP 3+ (xfreerdp, RemoteApp/RAIL) |
| Guest agent | PowerShell `HttpListener` on `127.0.0.1:8765` (bearer auth, base64 인코딩 `/exec` payload) |
| 컨테이너 | Podman / Docker ([dockur/windows](https://github.com/dockur/windows)) |
| VM | libvirt / KVM |
| Reverse-open shim | Rust (`windows_subsystem = "windows"`, vendored rcedit 로 슬러그별 아이콘 embed) |
| CI | GitHub Actions (lint + test on 3.9-3.13 + pip-audit) |

## 프로젝트 구조

```
winpodx/
├── install.sh             # 원라인 인스톨러 (pip 없음)
├── uninstall.sh           # 깔끔한 언인스톨러
├── src/winpodx/
│   ├── cli/               # argparse 명령 (app, pod, config, setup, host-open, ...)
│   ├── core/              # Config, RDP, pod lifecycle, provisioner, daemon
│   ├── backend/           # Podman, Docker, libvirt, manual
│   ├── desktop/           # .desktop 엔트리, 아이콘, MIME, tray, 알림
│   ├── display/           # X11/Wayland 감지, DPI 스케일링
│   ├── gui/               # Qt6 메인 윈도, 앱 다이얼로그, 테마, reverse-open Settings 카드
│   ├── reverse_open/      # Discovery, ICO 변환, listener daemon, sync transport
│   └── utils/             # XDG 경로, 의존성, TOML writer, winapps 호환
├── data/                  # winpodx GUI desktop 엔트리 + 아이콘 + 설정 예시
├── config/oem/
│   ├── install.bat        # Windows OEM 첫 부팅 오케스트레이션
│   └── reverse-open/      # register-apps.ps1, unregister-apps.ps1, Rust shim, rcedit
├── scripts/windows/       # PowerShell 스크립트 (debloat, time sync, USB mapping, 앱 discovery)
├── packaging/             # OBS / AUR / RHEL spec + 메인테이너 문서
├── debian/                # Debian 소스 패키지 레이아웃
├── docs/                  # 사용자 문서 (영어 + 한국어 mirror)
├── .github/workflows/     # CI: lint + test + publish (OBS / RHEL / deb / AUR)
└── tests/                 # pytest 테스트 스위트
```

## 주요 데이터 흐름

- **앱 실행.** CLI → `provisioner.ensure_ready()` (config + 비밀번호 회전 + compose + resume + pod + bundled apps + desktop 엔트리) → FreeRDP 세션 → `.cproc` 추적 + reaper 스레드 + desktop 알림.
- **앱 설치 (Linux 측).** AppInfo (TOML) → `.desktop` 파일 생성 → 아이콘 설치 → MIME 등록 → 아이콘 캐시 refresh.
- **파일 열기 (host → guest).** Linux 경로 → UNC 경로 변환 (`\\tsclient\home\...`) → RDP `/app-cmd`.
- **자동 suspend.** `daemon.run_idle_monitor()` → N 초 동안 세션 없으면 `podman pause` → lock 파일 정리.
- **자동 resume.** `provisioner` → `daemon.ensure_pod_awake()` → `podman unpause` → RDP 대기.
- **비밀번호 회전.** `ensure_ready()` → `password_max_age` 확인 → 새 비밀번호 생성 → config + compose 저장 → 컨테이너 재생성 → 실패 시 rollback.
- **Reverse-open (guest → host).** Windows Explorer "Open with..." → 슬러그별 `winpodx-<slug>.exe` shim → `\\tsclient\home\.local\share\winpodx\reverse-open\incoming\<uuid>.json` 에 atomic JSON 쓰기 → host listener 가 픽업 → `safe_open_unc` TOCTOU-safe 경로 해소 → 호스트에서 `xdg-open` 호출.
