import Foundation
import Speech
import AVFoundation
import CoreMedia

/// macOS 26+ SpeechAnalyzer 기반 온디바이스 영어 인식.
/// 시스템 받아쓰기(Dictation) 설정과 무관하게 동작하며, 모델은 최초 1회 자동 다운로드.
@available(macOS 26, *)
final class AnalyzerEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onStatus: ((String, Bool) -> Void)?
    var onAudio: ((AVAudioPCMBuffer) -> Void)?     // 마이크 원본 버퍼 (세션 녹음용, 탭 스레드에서 호출)

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    enum EngineError: Error, LocalizedError {
        case unsupportedLocale, noAudioFormat, converter
        var errorDescription: String? {
            switch self {
            case .unsupportedLocale: return "SpeechAnalyzer가 영어를 지원하지 않음"
            case .noAudioFormat: return "SpeechAnalyzer 오디오 포맷 없음"
            case .converter: return "오디오 변환기 생성 실패"
            }
        }
    }

    private func status(_ m: String, _ listening: Bool) {
        DispatchQueue.main.async { self.onStatus?(m, listening) }
    }

    func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            status("마이크 권한이 필요합니다 (시스템 설정 > 개인정보 보호 > 마이크)", false)
            throw EngineError.noAudioFormat
        }

        let locale = Locale(identifier: "en-US")
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw EngineError.unsupportedLocale
        }
        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        // 모델 확인/다운로드
        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        FileLog.write("analyzer asset status: \(assetStatus)")
        if assetStatus != .installed {
            status("영어 인식 모델 다운로드 중… (최초 1회)", false)
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await req.downloadAndInstall()
            }
            FileLog.write("analyzer asset installed")
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EngineError.noAudioFormat
        }
        analyzerFormat = fmt
        FileLog.write("analyzer format: \(fmt)")

        let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
        inputBuilder = builder

        // 결과 수신 루프: volatile(진행 중) → partial, finalized → final
        resultsTask = Task { [weak self] in
            var finalizedThrough = CMTime.zero   // 여기까지는 문장이 확정됨
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let self, !text.isEmpty else { continue }
                    if result.isFinal {
                        finalizedThrough = max(finalizedThrough, result.range.end)
                        DispatchQueue.main.async { self.onFinal?(text) }
                    } else {
                        // 이미 확정된 구간에 대한 늦은 volatile 결과는 무시 (확정 문장이 다시 '진행 중'으로 보이는 것 방지)
                        if result.range.start < finalizedThrough { continue }
                        DispatchQueue.main.async { self.onPartial?(text) }
                    }
                }
                FileLog.write("analyzer results ended")
            } catch {
                FileLog.write("analyzer results error: \(error)")
                self?.status("음성 인식 오류: \(error.localizedDescription)", false)
            }
        }

        try await analyzer.start(inputSequence: stream)

        // 마이크 → 변환 → analyzer
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        FileLog.write("input format: \(inFmt)")
        guard let conv = AVAudioConverter(from: inFmt, to: fmt) else { throw EngineError.converter }
        converter = conv

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [weak self] buffer, _ in
            guard let self else { return }
            self.onAudio?(buffer)
            guard let out = self.convert(buffer) else { return }
            self.inputBuilder?.yield(AnalyzerInput(buffer: out))
        }
        engine.prepare()
        try engine.start()
        status("듣는 중 (기기 내 인식 · SpeechAnalyzer)", true)
        FileLog.write("analyzer engine started")
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let conv = converter, let fmt = analyzerFormat else { return nil }
        if buffer.format == fmt { return buffer }
        let ratio = fmt.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: capacity) else { return nil }
        var consumed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let err { FileLog.write("convert error: \(err)"); return nil }
        return out.frameLength > 0 ? out : nil
    }

    func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        inputBuilder?.finish()
        inputBuilder = nil
        let a = analyzer
        Task { await a?.cancelAndFinishNow() }
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        status("일시정지", false)
    }
}
