import Foundation
import SwiftUI
import Translation
import FluidAudio
import AVFoundation

struct SubtitleLine: Identifiable, Equatable {
    let id: UUID
    var source: String      // 인식된 원문 (말하는 언어)
    var target: String      // 번역 (자막 언어)
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
    @Published var liveSource = ""                  // 지금 말하는 중인 원문 (partial)
    @Published var liveTarget = ""                  // 그 번역
    @Published var status = "준비 중…"
    @Published var isListening = false
    @Published var paused = false
    @Published var translationReady = false
    @Published var translationStatus = "번역 준비 중…"

    // 엔진 설정 (UserDefaults에 저장)
    @Published var engineChoice: EngineChoice = EngineChoice(rawValue: UserDefaults.standard.string(forKey: "engine") ?? "") ?? .parakeetV2
    @Published var latencyPreset: LatencyPreset = LatencyPreset(rawValue: UserDefaults.standard.string(forKey: "latency") ?? "") ?? .balanced

    // 언어 (UserDefaults에 저장): 말하는 언어 → 자막 언어
    @Published private(set) var sourceLanguage: String = UserDefaults.standard.string(forKey: "sourceLang") ?? "en"
    @Published private(set) var targetLanguage: String = UserDefaults.standard.string(forKey: "targetLang") ?? "ko"
    @Published private(set) var translationConfig = TranslationSession.Configuration(
        source: Locale.Language(identifier: UserDefaults.standard.string(forKey: "sourceLang") ?? "en"),
        target: Locale.Language(identifier: UserDefaults.standard.string(forKey: "targetLang") ?? "ko"))
    let languages = LanguageSupport()
    /// 말하는 언어와 자막 언어가 같으면 번역하지 않고 원문을 그대로 보여 줌
    var needsTranslation: Bool { !AppLanguage.matches(sourceLanguage, targetLanguage) }
    var languagePair: String { "\(AppLanguage.named(sourceLanguage).short) → \(AppLanguage.named(targetLanguage).short)" }

    // 표시 설정 (UserDefaults에 저장)
    @Published var showSource: Bool = UserDefaults.standard.object(forKey: "showSource") as? Bool ?? (UserDefaults.standard.object(forKey: "showEnglish") as? Bool ?? true) {
        didSet { UserDefaults.standard.set(showSource, forKey: "showSource") }
    }
    @Published var alwaysShowControls: Bool = UserDefaults.standard.object(forKey: "alwaysShowControls") as? Bool ?? true {
        didSet { UserDefaults.standard.set(alwaysShowControls, forKey: "alwaysShowControls") }
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

    /// 확정 문장 하나의 번역 지연 (메트릭 그래프용)
    struct LatencyPoint: Identifiable {
        let t: Date
        let ms: Double
        var id: Date { t }
    }

    // 세션 통계
    struct SessionStats {
        var start = Date()
        var sentences = 0
        var words = 0
        var asrUpdates = 0                    // 음성 인식 결과 수신 횟수 (partial + final)
        var engineRestarts = 0
        var translationMsSum: Double = 0
        var translationCount = 0
        var latencies: [LatencyPoint] = []    // 최근 2000개
        var avgTranslationMs: Double { translationCount > 0 ? translationMsSum / Double(translationCount) : 0 }
        var elapsedText: String {
            let s = Int(Date().timeIntervalSince(start))
            return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
        }
    }
    @Published var stats = SessionStats()

    /// 세션 모드 저장 (녹음 파트 · 시각 있는 전사 · 메트릭 → 세션 폴더)
    let recorder = SessionRecorder()

    private let speech: SpeechEngine             // 구형 API (macOS 15~, 받아쓰기 설정 필요) — 최후 폴백
    private var analyzerEngine: AnyObject?       // macOS 26+ SpeechAnalyzer — 2차 폴백
    private var parakeet: ParakeetEngine?        // Parakeet v2 CoreML — 기본
    private var usingAnalyzer = false
    private var liveID = UUID()
    private var liveStartedAt: Date?             // 현재 문장의 첫 partial 시각 (전사 시작 시각)
    private(set) var latestPartialSeq = 0
    private var seq = 0

    /// 번역 작업 큐. 언어가 바뀌면 SwiftUI가 translationTask를 다시 만들므로 루프마다 새 스트림을 쓴다.
    private var continuation: AsyncStream<TranslationEvent>.Continuation?

    init() {
        speech = SpeechEngine(locale: Locale(identifier: UserDefaults.standard.string(forKey: "sourceLang") ?? "en"))
        bind(&speech.onPartial, &speech.onFinal, &speech.onStatus, &speech.onAudio)
        Task { await languages.load(); await refreshPairStatus() }
    }

    // MARK: 언어

    /// 말하는 언어·자막 언어 변경. 현재 엔진이 그 언어를 못 들으면 들을 수 있는 엔진으로 자동 전환.
    func setLanguages(source: String? = nil, target: String? = nil) {
        let newSource = source ?? sourceLanguage
        let newTarget = target ?? targetLanguage
        let sourceChanged = newSource != sourceLanguage
        guard sourceChanged || newTarget != targetLanguage else { return }
        if !liveSource.isEmpty { handleFinal(liveSource) }
        sourceLanguage = newSource
        targetLanguage = newTarget
        UserDefaults.standard.set(newSource, forKey: "sourceLang")
        UserDefaults.standard.set(newTarget, forKey: "targetLang")
        translationConfig = TranslationSession.Configuration(source: Locale.Language(identifier: newSource), target: Locale.Language(identifier: newTarget))
        translationReady = !needsTranslation
        translationStatus = needsTranslation ? "번역 준비 중…" : "같은 언어 — 번역 없이 원문 표시"
        FileLog.write("languages: \(newSource) → \(newTarget)")
        if sourceChanged {
            let best = languages.bestEngine(for: newSource, preferred: engineChoice)
            if best != engineChoice {
                engineChoice = best
                UserDefaults.standard.set(best.rawValue, forKey: "engine")
                FileLog.write("engine auto-switched to \(best.rawValue) for \(newSource)")
            }
            if !paused { restartEngine() }
        }
        Task { await refreshPairStatus() }
    }

    private func refreshPairStatus() async {
        let s = await languages.checkPair(source: sourceLanguage, target: targetLanguage)
        if !translationReady { translationStatus = s }
    }

    /// 세션 파일에 기록할 엔진 이름
    var engineDescription: String {
        let pair = " · \(languagePair)"
        guard engineChoice.parakeetVersion != nil else { return engineChoice.short + pair }
        let preset = latencyPreset.title.components(separatedBy: " (").first ?? latencyPreset.rawValue
        return "\(engineChoice.short) · \(preset)" + pair
    }
    /// 발화 → 확정 텍스트 추정 지연(초). Parakeet 슬라이딩 창은 창 + 우측 문맥, Apple은 약 1.5초.
    var engineLagSeconds: Double {
        guard engineChoice.parakeetVersion != nil else { return 1.5 }
        let (chunk, _, right) = latencyPreset.window
        return chunk + right
    }

    /// 기본 모드 ↔ 세션 모드
    func setMode(_ m: AppMode) {
        recorder.setMode(m, engine: engineDescription, lag: engineLagSeconds, listening: isListening && !paused)
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
        recorder.sourceLanguage = sourceLanguage
        recorder.targetLanguage = targetLanguage
        recorder.engineStarted(engine: engineDescription, lag: engineLagSeconds)
    }

    func selectEngine(_ c: EngineChoice) {
        guard c != engineChoice else { return }
        if !languages.engineSupports(c, source: sourceLanguage) {
            status = "\(c.short)은(는) \(AppLanguage.named(sourceLanguage).name)을(를) 지원하지 않습니다"
            return
        }
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
        recorder.engineStopped()
        if let p = parakeet { p.stop(); parakeet = nil }
        if #available(macOS 26, *), usingAnalyzer, let eng = analyzerEngine as? AnalyzerEngine { eng.stop() }
        usingAnalyzer = false
        analyzerEngine = nil
        speech.stop()
    }

    func restartEngine() {
        stats.engineRestarts += 1
        FileLog.write("restart engine → \(engineChoice.rawValue) / \(latencyPreset.rawValue)")
        if !liveSource.isEmpty { handleFinal(liveSource) }
        stopCurrentEngine()
        start()
    }

    private func bind(_ onPartial: inout ((String) -> Void)?, _ onFinal: inout ((String) -> Void)?,
                      _ onStatus: inout ((String, Bool) -> Void)?, _ onAudio: inout ((AVAudioPCMBuffer) -> Void)?) {
        onPartial = { [weak self] text in self?.handlePartial(text) }
        onFinal = { [weak self] text in self?.handleFinal(text) }
        onStatus = { [weak self] msg, listening in
            self?.status = msg
            self?.isListening = listening
            FileLog.write("status: \(msg) listening=\(listening)")
        }
        let rec = recorder
        onAudio = { buffer in rec.write(buffer) }     // 오디오 탭 스레드 → 세션 녹음
    }

    private func startParakeet(version: AsrModelVersion) {
        let eng = ParakeetEngine(version: version, window: latencyPreset.window)
        bind(&eng.onPartial, &eng.onFinal, &eng.onStatus, &eng.onAudio)
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
            let eng = AnalyzerEngine(locale: Locale(identifier: sourceLanguage))
            bind(&eng.onPartial, &eng.onFinal, &eng.onStatus, &eng.onAudio)
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
            if !liveSource.isEmpty { handleFinal(liveSource) }
            stopCurrentEngine()
        }
    }

    /// 툴바 "모델 받기": 번역 언어 다운로드 창을 다시 띄움
    func requestModelDownload() {
        NSApp.activate(ignoringOtherApps: true)
        continuation?.yield(.prepare)
    }

    /// 시스템 설정 > 일반 > 언어 및 지역 (번역 언어 항목이 여기 있음)
    func openLanguageSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func clear() {
        history.removeAll()
        liveSource = ""
        liveTarget = ""
    }

    // MARK: 화면에 보여줄 것

    /// 큰 글씨로 보여줄 현재 줄: 말하는 중이면 live, 아니면 마지막 확정 문장
    var currentTarget: String {
        if !liveSource.isEmpty { return liveTarget.isEmpty ? "…" : liveTarget }
        guard let last = history.last else { return "" }
        return last.target.isEmpty ? last.source : last.target
    }
    var currentSource: String {
        if !liveSource.isEmpty { return liveSource }
        return history.last?.source ?? ""
    }
    /// 위에 흐리게 보여줄 직전 문장
    var previousTarget: String {
        let prev: String
        if !liveSource.isEmpty { prev = history.last?.target ?? "" }
        else { prev = history.count >= 2 ? history[history.count - 2].target : "" }
        return prev == currentTarget ? "" : prev     // 같은 문장이 두 줄로 보이지 않게
    }

    // MARK: 음성 인식 콜백

    private func handlePartial(_ text: String) {
        guard text != liveSource else { return }   // 같은 내용이 반복해서 오면 무시
        FileLog.write("partial: \(text)")
        stats.asrUpdates += 1
        if liveStartedAt == nil { liveStartedAt = Date() }
        liveSource = text
        seq += 1
        latestPartialSeq = seq
        if needsTranslation {
            continuation?.yield(.translate(TranslationJob(id: liveID, text: text, seq: seq, isFinal: false)))
        } else {
            liveTarget = text
        }
    }

    private func handleFinal(_ text: String) {
        FileLog.write("final \(AppLanguage.named(sourceLanguage).short): \(text)  [id=\(liveID.uuidString.prefix(4))]")
        let target = needsTranslation ? liveTarget : text
        let line = SubtitleLine(id: liveID, source: text, target: target)
        history.append(line)
        stats.sentences += 1
        stats.asrUpdates += 1
        stats.words += text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        recorder.addLine(id: liveID, startedAt: liveStartedAt, source: text, target: target)
        liveStartedAt = nil
        if history.count > 6 { history.removeFirst(history.count - 6) }
        seq += 1
        if needsTranslation {
            continuation?.yield(.translate(TranslationJob(id: liveID, text: text, seq: seq, isFinal: true)))
        }
        liveID = UUID()
        liveSource = ""
        liveTarget = ""
    }

    // MARK: 번역 루프 (SwiftUI .translationTask 안에서 실행됨)

    func runTranslationLoop(_ session: TranslationSession) async {
        // 언어가 바뀌면 이전 루프는 취소되고 새 세션으로 다시 들어옴 → 새 큐
        let (stream, cont) = AsyncStream<TranslationEvent>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        FileLog.write("translation loop: \(sourceLanguage) → \(targetLanguage)")
        guard needsTranslation else {
            translationReady = true
            translationStatus = "같은 언어 — 번역 없이 원문 표시"
            for await _ in stream {}      // 취소될 때까지 대기
            return
        }
        await prepare(session)

        for await event in stream {
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
                            let ms = Date().timeIntervalSince(t0) * 1000
                            stats.translationMsSum += ms
                            stats.translationCount += 1
                            stats.latencies.append(LatencyPoint(t: Date(), ms: ms))
                            if stats.latencies.count > 2000 { stats.latencies.removeFirst(stats.latencies.count - 2000) }
                        }
                        if job.isFinal { FileLog.write("final \(AppLanguage.named(targetLanguage).short): \(response.targetText)") }
                        else { FileLog.write("partial \(AppLanguage.named(targetLanguage).short): \(response.targetText)") }
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

    private func apply(_ job: TranslationJob, _ translated: String) {
        FileLog.write("apply \(job.isFinal ? "final" : "partial") id=\(job.id.uuidString.prefix(4)) live=\(liveID.uuidString.prefix(4)) src=\(job.text.prefix(30))")
        if job.isFinal {
            if let i = history.firstIndex(where: { $0.id == job.id }) {
                history[i].target = translated
            }
            recorder.updateTarget(id: job.id, target: translated)
        } else if job.id == liveID {
            liveTarget = translated
        }
    }
}
