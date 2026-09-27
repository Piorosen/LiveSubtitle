# 음성 인식 엔진 평가 (2026-09-28, MacBook Air M3 · 16GB · macOS 26.6)

목표: 학회장에서 노트북 마이크로 듣는 영어 강연을 실시간 한국어 자막으로. 원거리·잡음 환경 정확도가 핵심.

## 결과 요약

| 엔진 | 파라미터 | 디스크 | WER 원본 | WER 원거리 | 속도(배속) | 추가 전력 | 에너지/음성 1분 | 지연 | 앱 통합 |
|---|---|---|---|---|---|---|---|---|---|
| **Parakeet TDT 0.6B v2** (FluidAudio, CoreML) | 0.6B | 452 MB | **3.7%** | **7.4%** | 250× | 10.2 W | **2.4 J** | 1~9초 (창 설정) | 기본 |
| Parakeet Ultra (v3 기반) | 0.6B | 613 MB | 3.8% | 8.5% | 190× | 10.7 W | 3.4 J | 1~9초 | 선택 가능 |
| Apple SpeechAnalyzer (macOS 26 내장) | 비공개 | 0 | 5.8% | 17.3% | 63× | 6.3 W | 6.0 J | 약 1~2초 | 선택 가능 |
| WhisperKit large-v3-turbo (CoreML) | 0.8B | 606 MB | 4.7% | 12.6% | 13× | 5.1 W | 23.7 J | 수 초 | 측정만 |

- WER(단어 오류율)은 낮을수록 좋음. 원거리 시뮬에서 Parakeet v2는 Apple 대비 오류가 57% 적음.
- 에너지/분은 음성 1분을 인식하는 데 드는 추가 에너지. 실시간 자막의 평균 추가 전력은 이 값 ÷ 60 (Parakeet v2 ≈ 0.04 W, 배터리 영향 미미).

## Parakeet 스트리밍 창 크기 (지연 ↔ 정확도)

원거리 시뮬 긴 파일 12개(총 627초), 실제 앱과 같은 슬라이딩 창 방식으로 100ms씩 흘려 넣어 측정.

| 설정 | 창 / 좌 / 우 문맥 (초) | WER 원거리 | 자막 지연(대략) |
|---|---|---|---|
| 배치(참고, 상한) | 파일 전체 | 8.2% | - |
| 정확 | 7 / 2 / 2 | 8.4% | 2~9초 |
| 5 / 2 / 1.5 | 5 / 2 / 1.5 | 9.6% | 1.5~6.5초 |
| **균형 (기본)** | 4 / 3 / 1 | 10.0% | 1~5초 |
| 빠름 | 3 / 3 / 1 | 10.7% | 1~4초 |
| 2 / 4 / 1 | 2 / 4 / 1 | 12.0% | 1~3초 |
| Apple 내장(참고) | - | 18.7% | 1~2초 |

## 실제 학회 녹음(2분) 비교 발췌

같은 구간, 연사가 Linux RCU에 대해 말하는 부분.

- Apple: "...it's batching all the UC words... RCM work is pretty much matched... The RCU words are extremely fractured..."
- Parakeet v2: "...that's batching all the R C rewards... the RCU work is pretty much matched, right?... the RCU words are extremely fragmented. So every time I had like one or two RCU requests, I would instead get interrupted by a schedule..."
- WhisperKit: 문장 구성은 자연스러우나 처리 속도가 느림.

## 방법

- 데이터: LibriSpeech test-other에서 12화자 × 8발화 = 96개(총 610초). "원거리"는 ffmpeg로 잔향(aecho) + 150~3800Hz 대역 제한 + 분홍잡음(≈10dB SNR) 적용 → `eval/degrade.sh`.
- 채점: `eval/wer.py` (jiwer, 소문자·구두점 제거 후 단어 단위).
- Apple: `eval/applestt.swift` (SpeechAnalyzer 파일 전사). Parakeet: `eval/asreval` (FluidAudio 라이브러리, 배치) 및 `streamtest`(슬라이딩 창). WhisperKit: `brew install whisperkit-cli` 후 `--audio-folder`.
- 전력: 앱을 종료한 상태에서 `sudo powermetrics --samplers cpu_power,gpu_power,ane_power -i 1000` 을 켜고 627초 오디오를 배치 처리, 대기 전력(1.3W) 차감 → `eval/power.zsh`. Parakeet는 처리가 2~3초 만에 끝나 샘플 수가 1~2개로 적음(오차 큼).
- 모델은 모두 CoreML `.mlmodelc`(사전 컴파일) 형태로 HuggingFace에서 받으며, 최초 로드 시 이 기기의 Neural Engine용으로 한 번 더 컴파일·캐시됨 (v2 약 16초, Ultra 약 3분).

## 결론

기본 엔진을 Parakeet v2, 창 4초(균형)로 설정. 앱 툴바의 CPU 아이콘 또는 ⌘, 로 엔진과 지연 설정을 바꿀 수 있음.
