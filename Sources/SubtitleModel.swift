import Foundation
import SwiftUI
import Translation
import FluidAudio

struct SubtitleLine: Identifiable, Equatable {
    let id: UUID
    var english: String
    var korean: String
}

struct TranslationJob {
    let id: UUID
    let text: String
    let seq: Int
    let isFinal: Bool
}

enum TranslationEvent {
    case prepare                 // 언어 모델 다운로드/준비 (다운로드 창이 뜸)
    case translate(TranslationJob)
}

@MainActor
final class SubtitleModel: ObservableObject {
    @Published var history: [SubtitleLine] = []     // 확정된 문장들 (최근 몇 개만 유지)
    @Published var liveEnglish = ""                 // 지금 말하는 중인 영어 (partial)
    @Published var liveKorean = ""                  // 그 번역
    @Published var status = "준비 중…"
    @Published var isListening = false
    @Published var paused = false
    @Published var translationReady = false
    @Published var translationStatus = "번역 준비 중…"

    // 엔진 설정 (UserDefaults에 저장)
    @Published var engineChoice: EngineChoice = EngineChoice(rawValue: UserDefaults.standard.string(forKey: "engine") ?? "") ?? .parakeetV2
    @Published var latencyPreset: LatencyPreset = LatencyPreset(rawValue: UserDefaults.standard.string(forKey: "latency") ?? "") ?? .balanced

    // 표시 설정 (UserDefaults에 저장)
    @Published var showEnglish: Bool = UserDefaults.standard.object(forKey: "showEnglish") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showEnglish, forKey: "showEnglish") }
    }
    @Published var showPrevious: Bool = UserDefaults.standard.object(forKey: "showPrevious") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showPrevious, forKey: "showPrevious") }
    }
    @Published var fontSize: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "fontSize") as? Double ?? 34) {
        didSet { UserDefaults.standard.set(Double(fontSize), forKey: "fontSize") }
    }
    @Published var opacity: Double = UserDefaults.standard.object(forKey: "opacity") as? Double ?? 0.6 {
        didSet { UserDefaults.standard.set(opacity, forKey: "opacity") }
    }

    // 세션 통계
    struct SessionStats {
        var start = Date()
        var sentences = 0
        var engineRestarts = 0
        var translationMsSum: Double = 0
        var translationCount = 0
        var avgTranslationMs: Double { translationCount > 0 ? translationMsSum / Double(translationCount) : 0 }
        var elapsedText: String {
            let s = Int(Date().timeIntervalSince(start))
            return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
        }
    }
    @Published var stats = SessionStats()

    let translationConfig = TranslationSession.Configuration(
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "ko")
    )

    private let speech = SpeechEngine()          // 구형 API (macOS 15~, 받아쓰기 설정 필요) — 최후 폴백
    private var analyzerEngine: AnyObject?       // macOS 26+ SpeechAnalyzer — 2차 폴백
    private var parakeet: ParakeetEngine?        // Parakeet v2 CoreML — 기본
    private var usingAnalyzer = false
    private var liveID = UUID()
    private(set) var latestPartialSeq = 0
    private var seq = 0

    let jobs: AsyncStream<TranslationEvent>
    private let continuation: AsyncStream<TranslationEvent>.Continuation

    init() {
        var cont: AsyncStream<TranslationEvent>.Continuation!
        jobs = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont

        speech.onPartial = { [weak self] text in self?.handlePartial(text) }
        speech.onFinal = { [weak self] text in self?.handleFinal(text) }
        speech.onStatus = { [weak self] msg, listening in
            self?.status = msg
            self?.isListening = listening
            FileLog.write("status: \(msg) listening=\(listening)")
        }
    }

    func start() {
        paused = false
        if let env = ProcessInfo.processInfo.environment["LIVESUB_ENGINE"], let c = EngineChoice(rawValue: env) {
            engineChoice = c
        }
        if let v = engineChoice.parakeetVersion {
            startParakeet(version: v)
        } else {
            startAppleAnalyzer()
        }
    }

    func selectEngine(_ c: EngineChoice) {
        guard c != engineChoice else { return }
        engineChoice = c
        UserDefaults.standard.set(c.rawValue, forKey: "engine")
        restartEngine()
    }

    func selectPreset(_ p: LatencyPreset) {
        guard p != latencyPreset else { return }
        latencyPreset = p
        UserDefaults.standard.set(p.rawValue, forKey: "latency")
        if engineChoice.parakeetVersion != nil { restartEngine() }
    }

    private func stopCurrentEngine() {
        if let p = parakeet { p.stop(); parakeet = nil }
        if #available(macOS 26, *), usingAnalyzer, let eng = analyzerEngine as? AnalyzerEngine { eng.stop() }
        usingAnalyzer = false
        analyzerEngine = nil
        speech.stop()
    }

    func restartEngine() {
        stats.engineRestarts += 1
        FileLog.write("restart engine → \(engineChoice.rawValue) / \(latencyPreset.rawValue)")
        stopCurrentEngine()
        if !liveEnglish.isEmpty { handleFinal(liveEnglish) }
        start()
    }

    private func bind(_ onPartial: inout ((String) -> Void)?, _ onFinal: inout ((String) -> Void)?, _ onStatus: inout ((String, Bool) -> Void)?) {
        onPartial = { [weak self] text in self?.handlePartial(text) }
        onFinal = { [weak self] text in self?.handleFinal(text) }
        onStatus = { [weak self] msg, listening in
            self?.status = msg
            self?.isListening = listening
            FileLog.write("status: \(msg) listening=\(listening)")
        }
    }

    private func startParakeet(version: AsrModelVersion) {
        let eng = ParakeetEngine(version: version, window: latencyPreset.window)
        bind(&eng.onPartial, &eng.onFinal, &eng.onStatus)
        parakeet = eng
        status = "Parakeet 모델 준비 중…"
        Task {
            do {
                try await eng.start()
            } catch {
                FileLog.write("parakeet start failed: \(error) — falling back to Apple SpeechAnalyzer")
                self.parakeet = nil
                self.startAppleAnalyzer()
            }
        }
    }

    private func startAppleAnalyzer() {
        if #available(macOS 26, *) {
            let eng = AnalyzerEngine()
            bind(&eng.onPartial, &eng.onFinal, &eng.onStatus)
            analyzerEngine = eng
            usingAnalyzer = true
            status = "음성 인식 준비 중…"
            Task {
                do {
                    try await eng.start()
                } catch {
                    FileLog.write("analyzer start failed: \(error) — falling back to SFSpeechRecognizer")
                    self.usingAnalyzer = false
                    self.analyzerEngine = nil
                    self.speech.start()
                }
            }
        } else {
            speech.start()
        }
    }

    func togglePause() {
        if paused {
            start()
        } else {
            paused = true
            stopCurrentEngine()
            if !liveEnglish.isEmpty { handleFinal(liveEnglish) }
        }
    }

    /// 툴바 "모델 받기": 번역 언어 다운로드 창을 다시 띄움
    func requestModelDownload() {
        NSApp.activate(ignoringOtherApps: true)
        continuation.yield(.prepare)
    }

    /// 시스템 설정 > 일반 > 언어 및 지역 (번역 언어 항목이 여기 있음)
    func openLanguageSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func clear() {
        history.removeAll()
        liveEnglish = ""
        liveKorean = ""
    }

    // MARK: 화면에 보여줄 것

    /// 큰 글씨로 보여줄 현재 줄: 말하는 중이면 live, 아니면 마지막 확정 문장
    var currentKorean: String {
        if !liveEnglish.isEmpty { return liveKorean.isEmpty ? "…" : liveKorean }
        guard let last = history.last else { return "" }
        return last.korean.isEmpty ? last.english : last.korean
    }
    var currentEnglish: String {
        if !liveEnglish.isEmpty { return liveEnglish }
        return history.last?.english ?? ""
    }
    /// 위에 흐리게 보여줄 직전 문장
    var previousKorean: String {
        let prev: String
        if !liveEnglish.isEmpty { prev = history.last?.korean ?? "" }
        else { prev = history.count >= 2 ? history[history.count - 2].korean : "" }
        return prev == currentKorean ? "" : prev     // 같은 문장이 두 줄로 보이지 않게
    }

    // MARK: 음성 인식 콜백

    private func handlePartial(_ text: String) {
        guard text != liveEnglish else { return }   // 같은 내용이 반복해서 오면 무시
        FileLog.write("partial: \(text)")
        liveEnglish = text
        seq += 1
        latestPartialSeq = seq
        continuation.yield(.translate(TranslationJob(id: liveID, text: text, seq: seq, isFinal: false)))
    }

    private func handleFinal(_ text: String) {
        FileLog.write("final EN: \(text)  [id=\(liveID.uuidString.prefix(4))]")
        let line = SubtitleLine(id: liveID, english: text, korean: liveKorean)
        history.append(line)
        stats.sentences += 1
        if history.count > 6 { history.removeFirst(history.count - 6) }
        seq += 1
        continuation.yield(.translate(TranslationJob(id: liveID, text: text, seq: seq, isFinal: true)))
        liveID = UUID()
        liveEnglish = ""
        liveKorean = ""
    }

    // MARK: 번역 루프 (SwiftUI .translationTask 안에서 실행됨)

    func runTranslationLoop(_ session: TranslationSession) async {
        await prepare(session)

        for await event in jobs {
            switch event {
            case .prepare:
                await prepare(session)

            case .translate(let job):
                // 더 새로운 partial이 이미 들어왔으면 이건 건너뜀 (지연 누적 방지)
                if !job.isFinal && job.seq < latestPartialSeq { continue }
                var attempt = 0
                while attempt < 2 {
                    attempt += 1
                    do {
                        let t0 = Date()
                        let response = try await session.translate(job.text)
                        if job.isFinal {
                            stats.translationMsSum += Date().timeIntervalSince(t0) * 1000
                            stats.translationCount += 1
                        }
                        if job.isFinal { FileLog.write("final KO: \(response.targetText)") }
                        else { FileLog.write("partial KO: \(response.targetText)") }
                        if !translationReady {
                            translationReady = true
                            translationStatus = "번역 준비 완료"
                        }
                        apply(job, response.targetText)
                        break
                    } catch {
                        FileLog.write("translate failed (try \(attempt)): \(error.localizedDescription)")
                        let msg = error.localizedDescription
                        // 취소(서비스 워밍업 등)는 한 번 더 시도, 그 외는 그냥 건너뜀 (모델 없음으로 표시하지 않음)
                        if msg.lowercased().contains("cancel") && attempt < 2 { continue }
                        translationStatus = "번역 일시 오류: \(msg)"
                        break
                    }
                }
            }
        }
    }

    private func prepare(_ session: TranslationSession) async {
        translationStatus = "번역 모델 확인 중…"
        do {
            try await session.prepareTranslation()   // 언어 모델이 없으면 다운로드 창이 뜸
            translationReady = true
            translationStatus = "번역 준비 완료"
            FileLog.write("translation ready")
        } catch {
            translationReady = false
            translationStatus = "번역 모델 없음 (\(error.localizedDescription))"
            FileLog.write("translation prepare failed: \(error.localizedDescription)")
        }
    }

    private func apply(_ job: TranslationJob, _ korean: String) {
        FileLog.write("apply \(job.isFinal ? "final" : "partial") id=\(job.id.uuidString.prefix(4)) live=\(liveID.uuidString.prefix(4)) en=\(job.text.prefix(30))")
        if job.isFinal {
            if let i = history.firstIndex(where: { $0.id == job.id }) {
                history[i].korean = korean
            }
        } else if job.id == liveID {
            liveKorean = korean
        }
    }
}
