import Foundation

/// 2026-09-28 MacBook Air (Apple M3, 16GB, macOS 26.6) 실측값. 재현 방법: eval/ 폴더와 EVAL.md.
/// - WER: LibriSpeech test-other 96개 발화(12화자). "원거리"는 같은 파일에 잔향+저역통과+분홍잡음(≈10dB SNR) 적용.
/// - 속도/전력: 12개 화자별 연결 파일(총 627초)을 배치 처리하며 powermetrics(1초 간격)로 CPU+GPU+ANE 전력 측정, 대기 전력(1.3W) 차감.
/// - 에너지/분: 음성 1분을 인식하는 데 드는 추가 에너지(J). 실시간 자막에서는 이 값 ÷ 60 이 평균 추가 전력(W).
enum EngineMeasurements {
    static let rows: [EngineInfo] = [
        EngineInfo(choice: .parakeetV2, name: "Parakeet TDT 0.6B v2", params: "0.6B", diskMB: 452,
                   werClean: 3.7, werFar: 7.4, rtfx: 250, powerW: 10.2, energyJPerMin: 2.4,
                   latency: "1~9초 (창 설정)", offline: true, selectable: true,
                   note: "NVIDIA Parakeet, CoreML/Neural Engine. 영어 전용. 원거리 마이크에서 가장 정확하고 에너지 효율 최고. 스트리밍 창 7초: 8.4% / 4초: 10.0% / 3초: 10.7% (원거리 긴 파일 기준, 배치 8.2%)."),
        EngineInfo(choice: .parakeetUltra, name: "Parakeet Ultra (v3 기반)", params: "0.6B", diskMB: 613,
                   werClean: 3.8, werFar: 8.5, rtfx: 190, powerW: 10.7, energyJPerMin: 3.4,
                   latency: "1~9초 (창 설정)", offline: true, selectable: true,
                   note: "25개 유럽 언어 지원(여기서는 영어만 사용). v2보다 원거리에서 약간 부정확. 최초 로드 시 Neural Engine 컴파일에 약 3분."),
        EngineInfo(choice: .apple, name: "Apple SpeechAnalyzer (내장)", params: "비공개", diskMB: 0,
                   werClean: 5.8, werFar: 17.3, rtfx: 63, powerW: 6.3, energyJPerMin: 6.0,
                   latency: "약 1~2초", offline: true, selectable: true,
                   note: "macOS 26 내장. 다운로드 없음, 지연 최소. 원거리·잡음에서 오류가 2배 이상."),
        EngineInfo(choice: nil, name: "WhisperKit large-v3-turbo", params: "0.8B", diskMB: 606,
                   werClean: 4.7, werFar: 12.6, rtfx: 13, powerW: 5.1, energyJPerMin: 23.7,
                   latency: "수 초", offline: true, selectable: false,
                   note: "측정만 함(앱에 미통합). Parakeet보다 원거리 정확도 낮고 에너지 10배. 다국어·전문용어에는 강점."),
    ]
}
