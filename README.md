# LiveSubtitle — 실시간 다국어 자막 오버레이 (macOS)

연설자의 음성을 마이크로 듣고, 원하는 언어로 번역해 화면 하단에 반투명 자막으로 띄웁니다. 기본은 영어 → 한국어이고, **말하는 언어와 자막 언어를 각각 고를 수 있습니다** (메뉴바 > 언어, 설정 > 엔진, 자막 창의 `EN → KO` pill).
음성 인식은 **NVIDIA Parakeet TDT 0.6B v2 (CoreML, Neural Engine, 영어 전용)** 를 기본으로 쓰고, 유럽 25개 언어는 Parakeet Ultra(자동 감지), 한국어·일본어·중국어 등 그 밖의 언어는 Apple 내장 SpeechAnalyzer가 맡습니다. 말하는 언어를 바꾸면 들을 수 있는 엔진으로 자동 전환됩니다.
번역은 Apple **기기 내 번역(Translation 프레임워크)** 이며 지원 언어 간 어느 조합이든 됩니다. API 키나 인터넷이 필요 없습니다 (조합마다 최초 1회 모델 다운로드만). 말하는 언어와 자막 언어가 같으면 번역 없이 원문만 표시합니다.
두 가지 모드가 있습니다. **기본 모드**는 자막만 보여 주고 아무것도 저장하지 않습니다. **세션 모드**는 iCloud Drive(또는 이 맥)의 세션 폴더에 **녹음(m4a) · 문장별 절대 시각이 붙은 전사(json/md) · 자원 메트릭(csv)** 을 구조화해 저장하며, 나중에 Photos의 촬영 시각과 맞춰 pptx로 내보내는 것을 염두에 둔 형식입니다. **세션 보기** 창에서 저장된 세션의 자막 타임라인·그래프·재생을 볼 수 있고, 설정의 **메트릭** 탭에서 실시간 CPU·메모리·전력·번역 지연·처리량 그래프를 봅니다.
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

- **메뉴바 아이콘(말풍선)**: 자막 창 보이기/숨기기, **세션 시작/종료**(세션 모드면 녹음 시간·문장 수 표시), 세션 보기, 현재 상태·CPU·메모리, 일시정지, 자막 지우기, 엔진 빠른 전환, 세션 파일(폴더 열기·새 세션으로 나누기), 설정, 종료
- **자막 창**: 항상 다른 창 위에 뜨고, 배경을 잡고 드래그하면 이동, 가장자리를 끌면 크기 조절. 컨트롤 줄에 상태, **세션 시작 pill**(세션 모드면 빨간 ● 녹음 시간 · 문장 수), 세션 보기, 일시정지, 설정, 숨기기 버튼. 큰 흰 글씨 = 현재 문장 한국어, 노란 작은 글씨 = 영어 원문, 위 흐린 글씨 = 직전 문장
- **설정 (⌘,)**
  - 엔진: 말하는 언어·자막 언어(이 맥에서 인식·번역이 지원되는 언어만 활성, 조합별 번역 모델 상태), Parakeet v2 / Parakeet Ultra / Apple 내장 선택, 지연↔정확도 프리셋(정확/균형/빠름), 번역 상태, 엔진별 실측 비교표
  - 자막: 글자 크기, 배경 불투명도, 영어 원문·직전 문장 표시, 창 위치 초기화
  - 세션: 기본/세션 모드, 저장 위치(iCloud Drive / 이 맥 / 직접 선택), 세션 폴더 구조, 현재 세션 상태, 세션 보기 (아래 "세션 모드" 참고)
  - 리소스: 이 앱의 CPU·메모리·스레드, 모델 캐시 용량, 시스템 CPU·소비 전력·열 상태·저전력 모드·배터리, 세션 통계(문장·단어 수, 번역 지연), 로그 열기
  - 메트릭: 최근 1·5·10·30분의 CPU(앱/시스템)·메모리·시스템 전력·번역 지연·처리량(단어/분, 인식 결과/분) 그래프, CSV 내보내기
  - 정보: 버전, 사용 구성요소·라이선스, 단축키
- **자막 창을 숨겼다가 다시 보려면**: 어디서나 **⌥⌘L**, 또는 메뉴바의 "자막" 아이콘을 눌러 맨 위의 **자막 창 보이기**. 앱을 다시 켜면 항상 자막 창이 보이는 상태로 시작합니다. 노치 맥북에서 메뉴바가 꽉 차면 아이콘이 가려질 수 있는데, 그때도 ⌥⌘L은 동작합니다.
- 자막 창 위의 컨트롤 줄(상태·일시정지·설정·숨기기)은 기본적으로 항상 표시되며, 설정 > 자막에서 마우스를 올릴 때만 보이도록 바꿀 수 있습니다.
- 모든 설정(엔진, 프리셋, 글자, 투명도, 표시 옵션, 창 위치·크기)은 자동 저장되어 다음 실행 때 복원됩니다.
- 단축키: `⌥⌘L` 자막 창 보이기/숨기기(전역), `⌘R` 세션 시작/종료, `⌘L` 세션 보기, `⌘,` 설정, `⌘P` 일시정지/재개, `⌘K` 자막 지우기, `⌘=`/`⌘-` 글자 크기, `⌘E` 원문 표시, `⌘Q` 종료
- 언어: 메뉴바 > **언어** 서브메뉴(말하는 언어 / 자막 언어)에서 바로 바꿀 수 있습니다. 세션 파일(`session.json`, `transcript.json`의 `source`/`target`)에도 언어가 기록됩니다.

## 세션 모드

자막 창의 **세션 시작** pill, 메뉴바, 또는 `⌘R`로 켭니다. 켜져 있는 동안 아래 구조로 계속 저장하고(10초마다 전사·메타데이터 갱신), 세션 종료·앱 종료 시 마무리합니다. 모드는 다음 실행 때도 유지되어 앱을 다시 켜면 새 세션이 바로 시작됩니다 (자막 창에 빨간 ● 표시).

```
iCloud Drive/LiveSubtitle/Sessions/2026-09-29 09-15-02/     (기본 위치, 없으면 ~/Documents/LiveSubtitle/Sessions)
├── session.json        시각(시간대 포함)·엔진·추정 인식 지연·녹음 파트 목록(절대 시작 시각·길이)·문장/단어 수
├── transcript.json     문장마다 startedAt / endedAt(절대 시각) + 녹음 파트·위치(초) + source(원문)·target(번역)·단어 수
├── transcript.md       사람이 읽는 전사
├── metrics.csv         1초 간격: 앱·시스템 CPU, 메모리, 스레드, 시스템 전력(W), 열 상태, 누적 문장·단어, 번역 지연
├── audio/part-001.m4a  녹음 (AAC 64kbps, 약 30 MB/시간). 5초 조각 기록이라 앱이 죽어도 마지막 5초만 잃음
│   └── part-002.m4a    일시정지·엔진 전환·포맷 변경마다 새 파트 (각 파트의 절대 시작 시각은 session.json에)
├── photos.json         Photos에서 가져온 사진 목록: 촬영 시각, 앵커 문장 index, 제외 여부 (세션 보기 > 사진 가져오기)
└── photos/001.jpg …    가져온 사진 (최대 2048px JPEG), photos/thumbs/ 에 320px 썸네일
```

- **세션 보기** (자막 창의 목록 아이콘, 메뉴바, `⌘L`): 저장된 세션 목록(iCloud Drive·이 맥·이전 형식 모두), 길이·문장·단어·사진·CPU·전력 요약, 검색 가능한 자막 타임라인(줄을 클릭하면 그 위치부터 재생, 사진 썸네일 포함), 사진 기준 슬라이드 미리보기, 분당 단어 수·CPU·메모리·전력 그래프. 기록 중인 세션은 ● 표시되고 문장이 확정될 때마다 갱신됩니다.
- **사진 가져오기 (Photos)**: 세션 시간 범위(앞뒤 5분)의 사진을 Photos 보관함에서 찾아 `photos/`에 복사하고, 촬영 시각에 가장 가까운 문장에 붙입니다(문장 시각은 인식 지연 `engineLagSeconds`만큼 앞당겨 발화 시각으로 봄). 아이폰 사진은 iCloud 사진이 켜져 있으면 맥 Photos에 들어오므로 그대로 잡힙니다. 처음 누를 때 **사진 보관함 접근** 권한 창이 뜹니다(거절했다면 시스템 설정 > 개인정보 보호 및 보안 > 사진). 썸네일을 오른쪽 클릭하면 이전/다음 문장으로 옮기거나 제외할 수 있고, 다시 가져와도 이미 가져온 사진과 조정 내용은 유지됩니다.
- **pptx 내보내기**: 세션 보기의 **pptx** 메뉴. 사진 한 장(같은 문장에 붙은 여러 장은 함께)이 슬라이드 하나이고, 그 사진의 앵커 문장부터 다음 사진의 앵커 전까지가 그 슬라이드의 텍스트입니다. 첫 사진 앞의 문장과 사진이 없는 세션은 텍스트만. 문장이 많으면 같은 사진을 유지한 채 이어지는 슬라이드로 나뉩니다(사진 슬라이드 6문장, 텍스트 슬라이드 9문장). 영어 원문 포함 여부를 고를 수 있고, 각 슬라이드 바닥글에 시각 범위가 들어갑니다. 16:9, 외부 라이브러리 없이 OOXML을 직접 생성합니다.
- 소비 전력(W)은 배터리로 동작할 때 배터리 순간 전류×전압으로 구한 **맥 전체** 값입니다. 전원 연결 중에는 측정할 수 없고, 앱 하나의 전력이나 Neural Engine 전력은 macOS가 일반 앱에 제공하지 않습니다 (엔진별 실측은 EVAL.md).
- 인식·번역은 모두 기기 내 처리입니다. 세션 모드에서 저장 위치를 iCloud Drive로 둔 경우에만 음성·텍스트가 iCloud로 올라갑니다.

## 팁

- 마이크가 연설자와 가까울수록 정확합니다. 노트북 마이크는 앞쪽 좌석에서 잘 됩니다.
- 툴바 상태에 현재 엔진이 표시됩니다. Parakeet 로드에 실패하면 Apple SpeechAnalyzer로, 그것도 안 되면 구형 SFSpeechRecognizer(받아쓰기 설정 필요)로 자동 폴백합니다.
- 환경변수 `LIVESUB_ENGINE=apple|parakeetV2|parakeetUltra` 로 엔진을 강제할 수 있고, `LIVESUB_RECORD=<wav>` 로 마이크 입력을 녹음할 수 있습니다(평가용).
- 문제가 생기면 `~/Library/Logs/LiveSubtitle.log` 에 인식/번역 결과와 오류가 기록됩니다.
- 디버그: `open --env LIVESUB_SNAPSHOT=/tmp/snap.png build/LiveSubtitle.app` 으로 실행하면 2초마다 창 내용을 PNG로 저장합니다. `LIVESUB_SHOW_SETTINGS=1`로 설정 창을, `LIVESUB_SHOW_SESSIONS=1`로 세션 창을 자동으로 열고, `LIVESUB_SETTINGS_TAB=engine|subtitle|session|resources|metrics|about`로 설정 창의 처음 탭을 고릅니다.

## 구조

| 파일 | 역할 |
|---|---|
| `Sources/main.swift` | 앱 진입점, 메뉴바 아이템, 자막 오버레이 창, 설정 창, 단축키 |
| `Sources/SettingsView.swift` | 설정 창 (엔진 / 자막 / 세션 / 리소스 / 메트릭 / 정보 탭) |
| `Sources/MetricsView.swift`, `ChartPalette.swift` | 메트릭 탭: 실시간 Swift Charts 그래프(CPU·메모리·전력·번역 지연·처리량), CSV 내보내기, 계열 색 |
| `Sources/SessionRecorder.swift` | 세션 모드: AAC 조각 녹음 파트(AVAssetWriter), session.json / transcript.json / transcript.md / metrics.csv, 저장 위치(iCloud Drive) |
| `Sources/SessionBrowser.swift` | 세션 보기 창: 저장된 세션 읽기(이전 형식 포함), 자막 타임라인·검색·재생, 사진 페이지, 세션 그래프 |
| `Sources/PhotoImporter.swift` | PhotoKit으로 세션 시간 범위의 사진을 가져와 촬영 시각으로 문장에 앵커, photos.json |
| `Sources/PptxExporter.swift` | 세션 → .pptx (OOXML 직접 생성: 사진 슬라이드 + 텍스트 슬라이드) |
| `Sources/ResourceMonitor.swift` | CPU·메모리·스레드·시스템 전력·열 상태·배터리 1초 표본화, 최근 30분 보관 |
| `Sources/ParakeetEngine.swift` | Parakeet TDT CoreML 스트리밍 인식 (기본, FluidAudio) |
| `Sources/EngineCatalog.swift`, `EngineMeasurements.swift` | 엔진 목록과 실측 비교표 데이터 |
| `Sources/Languages.swift` | 선택 가능한 언어 목록, 엔진별 지원 언어, Apple 번역·인식 지원 언어 실행 시 조회 |
| `Sources/AnalyzerEngine.swift` | macOS 26 SpeechAnalyzer 온디바이스 인식 (대안) |
| `Sources/SpeechEngine.swift` | 구형 SFSpeechRecognizer 폴백 (macOS 15, 받아쓰기 필요) |
| `Sources/FileLog.swift` | `~/Library/Logs/LiveSubtitle.log` 기록 |
| `Sources/SubtitleModel.swift` | 자막 상태, 번역 작업 큐 (오래된 부분 결과는 건너뜀) |
| `Sources/SubtitleView.swift` | 자막 오버레이 화면 + 번역 세션 |
| `Info.plist` | 마이크/음성 인식/사진 보관함 사용 설명 (권한 창 문구) |
| `Package.swift`, `build.sh` / `run.sh` | SwiftPM 빌드(FluidAudio 의존) → `.app` 번들 → ad-hoc 서명 |
| `eval/`, `EVAL.md` | 엔진 평가 도구(WER, 스트리밍, 전력)와 결과 |

## App Sandbox · Mac App Store

앱은 App Sandbox 안에서도 동작하도록 만들어져 있습니다 (홈 폴더 직접 접근 없음, 외부 프로세스 없음).

- 저장 위치: 샌드박스에서는 iCloud 컨테이너(`iCloud Drive/LiveSubtitle`, App Store 빌드), 앱 컨테이너의 Documents, 또는 사용자가 고른 폴더(보안 북마크로 다음 실행에도 유지) 중 하나. 비샌드박스 빌드(`./build.sh`, GitHub Release DMG)는 지금처럼 iCloud Drive 폴더에 직접 씁니다.
- pptx 는 앱 안의 zip 생성기(`Sources/ZipWriter.swift`)로 만들며 `/usr/bin/zip` 을 쓰지 않습니다. 로그·모델 캐시는 컨테이너 안 Library 로 갑니다.
- entitlements 세 가지: `LiveSubtitle.entitlements`(Developer ID, 비샌드박스), `LiveSubtitle.sandbox.entitlements`(샌드박스 검증용, ad-hoc 서명 가능), `LiveSubtitle.appstore.entitlements`(샌드박스 + iCloud 컨테이너, TEAM_ID 치환).

```zsh
SANDBOX=1 ./build.sh          # build/LiveSubtitle-sandbox.app — 샌드박스 동작 검증 (iCloud 컨테이너 제외)
TEAM_ID=ABCDE12345 PROFILE=~/Downloads/LiveSubtitle_AppStore.provisionprofile VERSION=1.2.0 ./build-appstore.sh
                              # dist/LiveSubtitle-1.2.0.pkg — Transporter 로 App Store Connect 에 업로드
```

App Store 제출에 필요한 것: Apple Developer Program, App ID `party.udon.livesubtitle` 에 iCloud(CloudDocuments, 컨테이너 `iCloud.party.udon.livesubtitle`) 기능, "3rd Party Mac Developer Application / Installer" 인증서, Mac App Store 프로비저닝 프로파일, App Store Connect 앱 등록(스크린샷, 개인정보 처리방침 URL — 음성·텍스트는 기기 밖으로 나가지 않음). `Info.plist` 에는 `LSApplicationCategoryType`, `ITSAppUsesNonExemptEncryption`, `NSUbiquitousContainers` 가 들어 있습니다.

## 배포 자동화 (GitHub Actions)

- `ci.yml`: main 푸시·PR 때 macOS 러너에서 빌드하고 `.app`을 아티팩트로 올립니다.
- `release.yml`: `v1.2.3` 형태의 태그를 푸시하면 버전을 Info.plist에 기록해 빌드하고, zip·DMG·SHA256을 만들어 GitHub Release를 생성합니다.
  - 저장소 secrets에 `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`를 넣으면 Developer ID 서명과 공증까지 자동으로 수행합니다. 없으면 ad-hoc 서명 빌드를 올립니다.

```zsh
git tag v1.0.0 && git push origin v1.0.0   # → Release 생성
```
