# LiveSubtitle — 실시간 영어 → 한국어 자막 오버레이 (macOS)

연설자의 영어 음성을 마이크로 듣고, 한국어로 번역해 화면 하단에 반투명 자막으로 띄웁니다.
음성 인식은 **NVIDIA Parakeet TDT 0.6B v2 (CoreML, Neural Engine)** 를 기본으로 쓰고, Apple 내장 SpeechAnalyzer로도 바꿀 수 있습니다.
번역은 Apple **기기 내 번역(Translation 프레임워크)** 입니다. API 키나 인터넷이 필요 없습니다 (최초 1회 모델 다운로드만).
엔진별 정확도·속도·전력 실측은 [EVAL.md](EVAL.md) 참고.

## 설치 (배포판)

[Releases](https://github.com/Piorosen/LiveSubtitle/releases)에서 최신 `LiveSubtitle-x.y.z-macos-arm64.dmg`를 받아 열고, 앱을 Applications로 드래그합니다.

- 요구사항: Apple Silicon 맥, macOS 15 이상 (Apple 내장 인식 엔진은 macOS 26)
- 공증되지 않은 빌드는 처음 열 때 경고가 뜹니다. **시스템 설정 > 개인정보 보호 및 보안 > 그래도 열기**, 또는 `xattr -dr com.apple.quarantine /Applications/LiveSubtitle.app`
- 첫 실행은 인터넷 연결 상태에서 (번역 언어 + Parakeet 모델 다운로드)

## 소스에서 실행

```zsh
git clone https://github.com/Piorosen/LiveSubtitle.git && cd LiveSubtitle
./run.sh          # 빌드 후 실행 (= ./build.sh && open build/LiveSubtitle.app)
```
Xcode 26 이상이 필요합니다.

처음 실행 시 순서대로 뜨는 창:
1. **마이크 권한** → 허용
2. **번역 언어 다운로드(영어/한국어)** → 다운로드 (없을 때만 뜸, 한 번만)
3. Parakeet 모델(452MB)은 자동으로 받아짐 (툴바 상태에 진행률 표시, 이후 Neural Engine 컴파일 약 15초)

권한을 거절했으면: 시스템 설정 > 개인정보 보호 및 보안 > 마이크 에서 LiveSubtitle 켜기.
번역 다운로드 창을 놓쳤으면: 툴바의 **[모델 받기]** 버튼, 또는 **[언어 설정]** → 시스템 설정 > 일반 > 언어 및 지역 > 번역 언어에서 영어·한국어 다운로드.

## 사용법

앱은 **메뉴바**에서 동작하며 Dock에는 나타나지 않습니다.

- **메뉴바 아이콘(말풍선)**: 현재 상태·CPU·메모리, 자막 창 보이기/숨기기, 일시정지, 자막 지우기, 엔진 빠른 전환, 설정, 종료
- **자막 창**: 항상 다른 창 위에 뜨고, 배경을 잡고 드래그하면 이동, 가장자리를 끌면 크기 조절. 마우스를 올리면 상태 줄과 일시정지·설정·숨기기 버튼이 나타남. 큰 흰 글씨 = 현재 문장 한국어, 노란 작은 글씨 = 영어 원문, 위 흐린 글씨 = 직전 문장
- **설정 (⌘,)**
  - 엔진: Parakeet v2 / Parakeet Ultra / Apple 내장 선택, 지연↔정확도 프리셋(정확/균형/빠름), 번역 상태, 엔진별 실측 비교표
  - 자막: 글자 크기, 배경 불투명도, 영어 원문·직전 문장 표시, 창 위치 초기화
  - 리소스: 이 앱의 CPU·메모리, 모델 캐시 용량, 시스템 CPU·열 상태·저전력 모드·배터리, 세션 통계(문장 수, 번역 지연), 로그 열기
  - 정보: 버전, 사용 구성요소·라이선스, 단축키
- **자막 창을 숨겼다가 다시 보려면**: 어디서나 **⌥⌘L**, 또는 메뉴바의 "자막" 아이콘을 눌러 맨 위의 **자막 창 보이기**. 앱을 다시 켜면 항상 자막 창이 보이는 상태로 시작합니다. 노치 맥북에서 메뉴바가 꽉 차면 아이콘이 가려질 수 있는데, 그때도 ⌥⌘L은 동작합니다.
- 자막 창 위의 컨트롤 줄(상태·일시정지·설정·숨기기)은 기본적으로 항상 표시되며, 설정 > 자막에서 마우스를 올릴 때만 보이도록 바꿀 수 있습니다.
- 모든 설정(엔진, 프리셋, 글자, 투명도, 표시 옵션, 창 위치·크기)은 자동 저장되어 다음 실행 때 복원됩니다.
- 단축키: `⌥⌘L` 자막 창 보이기/숨기기(전역), `⌘,` 설정, `⌘P` 일시정지/재개, `⌘K` 자막 지우기, `⌘=`/`⌘-` 글자 크기, `⌘E` 영어 원문, `⌘Q` 종료

## 팁

- 마이크가 연설자와 가까울수록 정확합니다. 노트북 마이크는 앞쪽 좌석에서 잘 됩니다.
- 툴바 상태에 현재 엔진이 표시됩니다. Parakeet 로드에 실패하면 Apple SpeechAnalyzer로, 그것도 안 되면 구형 SFSpeechRecognizer(받아쓰기 설정 필요)로 자동 폴백합니다.
- 환경변수 `LIVESUB_ENGINE=apple|parakeetV2|parakeetUltra` 로 엔진을 강제할 수 있고, `LIVESUB_RECORD=<wav>` 로 마이크 입력을 녹음할 수 있습니다(평가용).
- 문제가 생기면 `~/Library/Logs/LiveSubtitle.log` 에 인식/번역 결과와 오류가 기록됩니다.
- 디버그: `open --env LIVESUB_SNAPSHOT=/tmp/snap.png build/LiveSubtitle.app` 으로 실행하면 2초마다 창 내용을 PNG로 저장합니다.

## 구조

| 파일 | 역할 |
|---|---|
| `Sources/main.swift` | 앱 진입점, 메뉴바 아이템, 자막 오버레이 창, 설정 창, 단축키 |
| `Sources/SettingsView.swift` | 설정 창 (엔진 / 자막 / 리소스 / 정보 탭) |
| `Sources/ResourceMonitor.swift` | CPU·메모리·열 상태·배터리 표본화 |
| `Sources/ParakeetEngine.swift` | Parakeet TDT CoreML 스트리밍 인식 (기본, FluidAudio) |
| `Sources/EngineCatalog.swift`, `EngineMeasurements.swift` | 엔진 목록과 실측 비교표 데이터 |
| `Sources/AnalyzerEngine.swift` | macOS 26 SpeechAnalyzer 온디바이스 인식 (대안) |
| `Sources/SpeechEngine.swift` | 구형 SFSpeechRecognizer 폴백 (macOS 15, 받아쓰기 필요) |
| `Sources/FileLog.swift` | `~/Library/Logs/LiveSubtitle.log` 기록 |
| `Sources/SubtitleModel.swift` | 자막 상태, 번역 작업 큐 (오래된 부분 결과는 건너뜀) |
| `Sources/SubtitleView.swift` | 자막 오버레이 화면 + 번역 세션 |
| `Info.plist` | 마이크/음성 인식 사용 설명 (권한 창 문구) |
| `Package.swift`, `build.sh` / `run.sh` | SwiftPM 빌드(FluidAudio 의존) → `.app` 번들 → ad-hoc 서명 |
| `eval/`, `EVAL.md` | 엔진 평가 도구(WER, 스트리밍, 전력)와 결과 |

## 배포 자동화 (GitHub Actions)

- `ci.yml`: main 푸시·PR 때 macOS 러너에서 빌드하고 `.app`을 아티팩트로 올립니다.
- `release.yml`: `v1.2.3` 형태의 태그를 푸시하면 버전을 Info.plist에 기록해 빌드하고, zip·DMG·SHA256을 만들어 GitHub Release를 생성합니다.
  - 저장소 secrets에 `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`를 넣으면 Developer ID 서명과 공증까지 자동으로 수행합니다. 없으면 ad-hoc 서명 빌드를 올립니다.

```zsh
git tag v1.0.0 && git push origin v1.0.0   # → Release 생성
```
