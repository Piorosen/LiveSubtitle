import Foundation
import AVFoundation
import FluidAudio

/// NVIDIA Parakeet TDT 0.6B v2 (영어 전용, CoreML/ANE) 스트리밍 인식 — FluidAudio 라이브러리 사용.
/// 이 하드웨어(M3) 평가에서 Apple 내장 인식기 대비 원거리 마이크 WER 17.3% → 7.4% (EVAL.md 참고).
final class ParakeetEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onStatus: ((String, Bool) -> Void)?

    private let engine = AVAudioEngine()
    private var manager: SlidingWindowAsrManager?
    private var updatesTask: Task<Void, Never>?
    private var recordFile: AVAudioFile?
    private let version: AsrModelVersion
    private let window: (Double, Double, Double)   // (chunk, left, right) 초

    init(version: AsrModelVersion = .v2, window: (Double, Double, Double) = (4, 3, 1)) {
        self.version = version
        self.window = window
    }

    enum EngineError: Error, LocalizedError {
        case micDenied
        var errorDescription: String? { "마이크 권한 없음" }
    }

    private func status(_ m: String, _ listening: Bool) {
        DispatchQueue.main.async { self.onStatus?(m, listening) }
    }

    func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            status("마이크 권한이 필요합니다 (시스템 설정 > 개인정보 보호 > 마이크)", false)
            throw EngineError.micDenied
        }

        status("Parakeet 모델 준비 중… (최초 1회 다운로드 + Neural Engine 컴파일)", false)
        let t0 = Date()
        let models = try await AsrModels.downloadAndLoad(version: version) { [weak self] progress in
            let pct = Int(progress.fractionCompleted * 100)
            self?.status("Parakeet 모델 다운로드 중… \(pct)%", false)
        }
        FileLog.write("parakeet models loaded in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")

        // 슬라이딩 창: (창 + 좌우 문맥) ≤ 15초. 결과는 창마다 나오므로 자막 지연 ≈ 우측 문맥 ~ 창+우측 문맥.
        let (chunk, left, right) = window
        let config = SlidingWindowAsrConfig(
            chunkSeconds: chunk,
            hypothesisChunkSeconds: 1.0,
            leftContextSeconds: left,
            rightContextSeconds: right,
            minContextForConfirmation: chunk,
            confirmationThreshold: 0.80
        )
        let mgr = SlidingWindowAsrManager(config: config)
        try await mgr.loadModels(models)
        manager = mgr

        // 결과 수신: isConfirmed=false → 진행 중(partial), true → 확정(final). text는 현재 창의 텍스트.
        let updates = await mgr.transcriptionUpdates
        updatesTask = Task { [weak self] in
            for await u in updates {
                let text = u.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let self, !text.isEmpty else { continue }
                if u.isConfirmed {
                    DispatchQueue.main.async { self.onFinal?(text) }
                } else {
                    DispatchQueue.main.async { self.onPartial?(text) }
                }
            }
            FileLog.write("parakeet updates ended")
        }

        try await mgr.startStreaming(source: .microphone)

        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        FileLog.write("input format: \(inFmt)")
        if let path = ProcessInfo.processInfo.environment["LIVESUB_RECORD"] {
            recordFile = try? AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: inFmt.settings,
                                          commonFormat: inFmt.commonFormat, interleaved: inFmt.isInterleaved)
            FileLog.write("recording to \(path): \(recordFile != nil)")
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [weak self] buffer, _ in
            guard let self else { return }
            if let f = self.recordFile { try? f.write(from: buffer) }
            // 탭 버퍼는 콜백 이후 재사용될 수 있으므로 복사해서 넘김
            guard let copy = Self.copy(buffer) else { return }
            Task { await mgr.streamAudio(copy) }
        }
        engine.prepare()
        try engine.start()
        status("듣는 중 (Parakeet \(version == .v2 ? "v2" : "Ultra") · CoreML · 창 \(Int(chunk))초)", true)
        FileLog.write("parakeet engine started")
    }

    private static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let c = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength) else { return nil }
        c.frameLength = b.frameLength
        let ch = Int(b.format.channelCount)
        let n = Int(b.frameLength)
        if let src = b.floatChannelData, let dst = c.floatChannelData {
            for i in 0..<ch { dst[i].update(from: src[i], count: n) }
        } else if let src = b.int16ChannelData, let dst = c.int16ChannelData {
            for i in 0..<ch { dst[i].update(from: src[i], count: n) }
        } else if let src = b.int32ChannelData, let dst = c.int32ChannelData {
            for i in 0..<ch { dst[i].update(from: src[i], count: n) }
        } else { return nil }
        return c
    }

    func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        recordFile = nil
        updatesTask?.cancel()
        updatesTask = nil
        let m = manager
        manager = nil
        Task { await m?.cancel() }
        status("일시정지", false)
    }
}
