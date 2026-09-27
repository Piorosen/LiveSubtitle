import Foundation
import FluidAudio

/// 선택 가능한 음성 인식 엔진
enum EngineChoice: String, CaseIterable, Identifiable {
    case parakeetV2, parakeetUltra, apple
    var id: String { rawValue }
    var title: String {
        switch self {
        case .parakeetV2: return "Parakeet TDT 0.6B v2 (영어 전용)"
        case .parakeetUltra: return "Parakeet Ultra (v3 기반, 다국어)"
        case .apple: return "Apple 내장 (SpeechAnalyzer)"
        }
    }
    var short: String {
        switch self {
        case .parakeetV2: return "Parakeet v2"
        case .parakeetUltra: return "Parakeet Ultra"
        case .apple: return "Apple"
        }
    }
    var parakeetVersion: AsrModelVersion? {
        switch self {
        case .parakeetV2: return .v2
        case .parakeetUltra: return .ultra
        case .apple: return nil
        }
    }
}

/// Parakeet 슬라이딩 창 크기: 지연 ↔ 정확도 트레이드오프 (EVAL.md 측정값)
enum LatencyPreset: String, CaseIterable, Identifiable {
    case accurate, balanced, fast
    var id: String { rawValue }
    var title: String {
        switch self {
        case .accurate: return "정확 (창 7초, 지연 2~9초)"
        case .balanced: return "균형 (창 4초, 지연 1~5초)"
        case .fast: return "빠름 (창 3초, 지연 1~4초)"
        }
    }
    /// (chunk, left, right) 초
    var window: (Double, Double, Double) {
        switch self {
        case .accurate: return (7, 2, 2)
        case .balanced: return (4, 3, 1)
        case .fast: return (3, 3, 1)
        }
    }
}

/// 이 맥(MacBook Air M3, 16GB)에서 2026-09-28 실측한 값. 측정 방법은 EVAL.md 참고.
struct EngineInfo: Identifiable {
    let choice: EngineChoice?
    let name: String
    let params: String        // 파라미터 수
    let diskMB: Int           // 디스크 용량
    let werClean: Double      // LibriSpeech test-other 96개, 원본
    let werFar: Double        // 같은 파일에 강당 잔향+잡음 시뮬레이션
    let rtfx: Double          // 실시간 대비 처리 속도 (배)
    let powerW: Double        // 인식 중 추가 소비 전력 (W, CPU+GPU+ANE, 대기 대비)
    let energyJPerMin: Double // 음성 1분당 에너지 (J)
    let latency: String
    let offline: Bool
    let selectable: Bool
    let note: String
    var id: String { name }
}

enum EngineCatalog {
    static let rows: [EngineInfo] = EngineMeasurements.rows
}
