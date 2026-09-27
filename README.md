# LiveSubtitle — 실시간 영어 → 한국어 자막 오버레이 (macOS)

연설자의 영어 음성을 마이크로 듣고, 한국어로 번역해 화면 하단에 반투명 자막으로 띄웁니다.
음성 인식은 **NVIDIA Parakeet TDT 0.6B v2 (CoreML, Neural Engine)** 를 기본으로 쓰고, Apple 내장 SpeechAnalyzer로도 바꿀 수 있습니다.
번역은 Apple **기기 내 번역(Translation 프레임워크)** 입니다. API 키나 인터넷이 필요 없습니다 (최초 1회 모델 다운로드만).
엔진별 정확도·속도·전력 실측은 [EVAL.md](EVAL.md) 참고.

## 실행

```zsh
cd LiveSubtitle
./run.sh          # 빌드 후 실행 (= ./build.sh && open build/LiveSubtitle.app)
```

처음 실행 시 순서대로 뜨는 창:
1. **마이크 권한** → 허용
2. **번역 언어 다운로드(영어/한국어)** → 다운로드 (없을 때만 뜸, 한 번만)
3. Parakeet 모델(452MB)은 자동으로 받아짐 (툴바 상태에 진행률 표시, 이후 Neural Engine 컴파일 약 15초)

권한을 거절했으면: 시스템 설정 > 개인정보 보호 및 보안 > 마이크 에서 LiveSubtitle 켜기.
번역 다운로드 창을 놓쳤으면: 툴바의 **[모델 받기]** 버튼, 또는 **[언어 설정]** → 시스템 설정 > 일반 > 언어 및 지역 > 번역 언어에서 영어·한국어 다운로드.

## 사용법

- 자막 창은 항상 다른 창 위에 뜨고, **배경을 잡고 드래그**하면 이동, 가장자리를 끌면 크기 조절.
- 마우스를 올리면 위에 툴바가 나타남: 인식/번역 상태 · **엔진 선택(CPU 아이콘)** · 모델 받기 · 언어 설정 · 일시정지 · 영어 원문 표시(EN) · 글자 크기 · 투명도 · 지우기 · 종료
- **엔진 선택 창 (⌘,)**: Parakeet v2 / Parakeet Ultra / Apple 내장 중 선택. 각 엔진의 모델 크기·정확도·속도·전력 실측 표가 함께 표시되고, Parakeet는 지연↔정확도 프리셋(정확/균형/빠름)을 고를 수 있음. 선택은 저장됨.
- 단축키: `⌘=` 글자 크게, `⌘-` 작게, `⌘E` 영어 원문 표시 전환, `⌘P` 일시정지/재개, `⌘K` 자막 지우기, `⌘,` 엔진 선택, `⌘Q` 종료
- 큰 흰 글씨 = 현재 문장 한국어, 노란 작은 글씨 = 영어 원문, 위 흐린 글씨 = 직전 문장

## 팁

- 마이크가 연설자와 가까울수록 정확합니다. 노트북 마이크는 앞쪽 좌석에서 잘 됩니다.
- 툴바 상태에 현재 엔진이 표시됩니다. Parakeet 로드에 실패하면 Apple SpeechAnalyzer로, 그것도 안 되면 구형 SFSpeechRecognizer(받아쓰기 설정 필요)로 자동 폴백합니다.
- 환경변수 `LIVESUB_ENGINE=apple|parakeetV2|parakeetUltra` 로 엔진을 강제할 수 있고, `LIVESUB_RECORD=<wav>` 로 마이크 입력을 녹음할 수 있습니다(평가용).
- 문제가 생기면 `~/Library/Logs/LiveSubtitle.log` 에 인식/번역 결과와 오류가 기록됩니다.
- 디버그: `open --env LIVESUB_SNAPSHOT=/tmp/snap.png build/LiveSubtitle.app` 으로 실행하면 2초마다 창 내용을 PNG로 저장합니다.

## 구조

| 파일 | 역할 |
|---|---|
| `Sources/main.swift` | 앱 진입점, 테두리 없는 반투명 항상-위 창, 메뉴/단축키 |
| `Sources/ParakeetEngine.swift` | Parakeet TDT CoreML 스트리밍 인식 (기본, FluidAudio) |
| `Sources/EngineCatalog.swift`, `EngineMeasurements.swift`, `EnginePickerView.swift` | 엔진 선택 UI와 실측 비교표 |
| `Sources/AnalyzerEngine.swift` | macOS 26 SpeechAnalyzer 온디바이스 인식 (대안) |
| `Sources/SpeechEngine.swift` | 구형 SFSpeechRecognizer 폴백 (macOS 15, 받아쓰기 필요) |
| `Sources/FileLog.swift` | `~/Library/Logs/LiveSubtitle.log` 기록 |
| `Sources/SubtitleModel.swift` | 자막 상태, 번역 작업 큐 (오래된 부분 결과는 건너뜀) |
| `Sources/SubtitleView.swift` | SwiftUI 자막 화면 + 호버 툴바 + 번역 세션 |
| `Info.plist` | 마이크/음성 인식 사용 설명 (권한 창 문구) |
| `Package.swift`, `build.sh` / `run.sh` | SwiftPM 빌드(FluidAudio 의존) → `.app` 번들 → ad-hoc 서명 |
| `eval/`, `EVAL.md` | 엔진 평가 도구(WER, 스트리밍, 전력)와 결과 |
