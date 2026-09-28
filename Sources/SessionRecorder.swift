import Foundation
import AVFoundation
import CoreMedia
import AppKit

/// 앱 동작 모드
enum AppMode: String, CaseIterable, Identifiable {
    case live      // 기본: 실시간 자막만, 아무것도 저장하지 않음
    case session   // 세션: 녹음 + 시각 있는 전사 + 메트릭을 폴더에 구조화해 저장
    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: return "기본 모드 (실시간 자막만)"
        case .session: return "세션 모드 (녹음 · 전사 · 메트릭 저장)"
        }
    }
}

/// 세션 파일 저장 위치
enum SaveLocation: String, CaseIterable, Identifiable {
    case iCloud, documents, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .iCloud: return "iCloud Drive  (iCloud Drive/LiveSubtitle/Sessions — 다른 기기와 동기화)"
        case .documents: return "이 맥  (~/Documents/LiveSubtitle/Sessions)"
        case .custom: return "직접 선택한 폴더"
        }
    }
}

/// 확정된 문장 하나. 절대 시각(startedAt/endedAt)과 녹음 파트 안의 위치를 함께 가진다 — 나중에 Photos 촬영 시각과 매칭하기 위한 핵심 데이터.
struct TranscriptLine: Identifiable, Equatable, Codable {
    let id: UUID
    let index: Int
    let startedAt: Date        // 이 문장의 첫 partial이 도착한 시각 (발화 시작 근사)
    let endedAt: Date          // 확정 시각
    let audioFile: String?     // 예: "audio/part-001.m4a" (녹음 파트)
    let audioStart: Double     // 파트 안의 위치(초)
    let audioEnd: Double
    var english: String
    var korean: String
    var words: Int
}

/// 녹음 파트: 엔진이 멈췄다 켜질 때마다(일시정지·엔진 전환·포맷 변경) 새 파일. 각 파트의 절대 시작 시각을 기록해 오디오 위치 ↔ 시각 변환이 가능하다.
struct AudioPart: Codable, Equatable {
    let file: String
    let startedAt: Date
    var endedAt: Date?
    var durationSeconds: Double
    let sampleRate: Double
    let channels: Int
}

/// session.json — 세션 메타데이터 (형식 버전 1)
struct SessionManifest: Codable {
    var format = "livesubtitle-session/1"
    var id: String
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var timeZone: String
    var engine: String
    var engineLagSeconds: Double        // 발화 → 확정 텍스트 추정 지연 (Parakeet: 창 + 우측 문맥)
    var audio: [AudioPart]
    var sentences: Int
    var words: Int
    var files: [String: String]         // transcript / transcriptMarkdown / metrics / photos (photos.json, 사진 가져오기 후 생성)
}

/// transcript.json
struct TranscriptDocument: Codable {
    var format = "livesubtitle-transcript/1"
    var sessionId: String
    var segments: [TranscriptLine]
}

/// 세션 모드에서 한 세션(시작 → 종료) 동안 아래 구조로 저장한다.
///   <저장 위치>/LiveSubtitle/Sessions/2026-09-29 09-15-02/
///     session.json        메타데이터: 시각, 엔진, 녹음 파트 목록(절대 시작 시각·길이)
///     transcript.json     문장별 절대 시각 + 녹음 위치 + 영어/한국어  (pptx·Photos 매칭용)
///     transcript.md       사람이 읽는 전사
///     metrics.csv         1초 간격 자원 사용량
///     audio/part-001.m4a  녹음 (AAC, 5초 조각 기록 → 비정상 종료에도 안전)
///     photos.json         Photos에서 가져온 사진 목록 + 앵커 문장 (세션 보기 > 사진 가져오기)
///     photos/NNN.jpg      가져온 사진 (최대 2048px), photos/thumbs/NNN.jpg 썸네일
@MainActor
final class SessionRecorder: ObservableObject {
    // MARK: 설정 (UserDefaults)

    @Published private(set) var mode: AppMode = AppMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .live
    @Published var location: SaveLocation = SaveLocation(rawValue: UserDefaults.standard.string(forKey: "rec.location") ?? "") ?? .iCloud {
        didSet { UserDefaults.standard.set(location.rawValue, forKey: "rec.location") }
    }
    @Published var customPath: String = UserDefaults.standard.string(forKey: "rec.customPath") ?? "" {
        didSet { UserDefaults.standard.set(customPath, forKey: "rec.customPath") }
    }

    // MARK: 상태 (UI 표시용)

    @Published private(set) var isActive = false
    @Published private(set) var sessionStart: Date?
    @Published private(set) var sessionURL: URL?
    @Published private(set) var audioSeconds: Double = 0      // 모든 파트 합계
    @Published private(set) var audioFileMB: Double = 0
    @Published private(set) var parts: [AudioPart] = []
    @Published private(set) var lines: [TranscriptLine] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastSavedAt: Date?

    var wordCount: Int { lines.reduce(0) { $0 + $1.words } }
    var sessionsRoot: URL { baseFolder.appendingPathComponent("LiveSubtitle/Sessions", isDirectory: true) }
    var usingICloud: Bool { location == .iCloud && Self.iCloudDriveRoot != nil }

    /// iCloud Drive 루트 (iCloud Drive를 켠 맥에만 존재)
    static var iCloudDriveRoot: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? url : nil
    }
    /// 이전 형식(폴더 바로 아래 transcript.md)이 저장되던 곳 — 세션 보기에서 함께 읽음
    static var legacyRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/LiveSubtitle", isDirectory: true)
    }

    private var baseFolder: URL {
        let docs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        switch location {
        case .iCloud: return Self.iCloudDriveRoot ?? docs
        case .documents: return docs
        case .custom: return customPath.isEmpty ? docs : URL(fileURLWithPath: customPath, isDirectory: true)
        }
    }

    private var sessionID = ""
    private var engineTitle = ""
    private var engineLag: Double = 0
    private var dirty = false
    private var timer: Timer?
    private var tick = 0
    private var metricsHeaderWritten = false

    // 오디오 탭 스레드에서 읽는 플래그 (메인에서만 씀)
    nonisolated(unsafe) private var activeFlag = false
    nonisolated(unsafe) private var evalWavPath: String?
    nonisolated(unsafe) private var evalWav: AVAudioFile?      // LIVESUB_RECORD=<wav>: 평가용 원본 녹음 (ioQ에서만 접근)

    private let ioQ = DispatchQueue(label: "livesub.session.io", qos: .utility)
    nonisolated(unsafe) private let audio = AudioWriter()      // ioQ에서만 접근

    // MARK: 모드

    /// 모드 전환. 세션 모드로 가면 (엔진이 듣는 중이면) 즉시 세션 시작, 기본 모드로 가면 세션 종료.
    func setMode(_ m: AppMode, engine: String, lag: Double, listening: Bool) {
        guard m != mode else { return }
        mode = m
        UserDefaults.standard.set(m.rawValue, forKey: "mode")
        switch m {
        case .session:
            engineTitle = engine; engineLag = lag
            beginSession()
            activeFlag = listening
        case .live:
            endSession(reason: "기본 모드로 전환")
        }
    }

    // MARK: 세션 수명 (SubtitleModel이 엔진 상태에 따라 호출)

    /// 엔진이 (다시) 듣기 시작. 세션 모드면 세션이 없을 때 새로 만들고, 다음 오디오 버퍼부터 새 파트를 연다.
    func engineStarted(engine: String, lag: Double) {
        engineTitle = engine
        engineLag = lag
        guard mode == .session else { return }
        if !isActive { beginSession() }
        activeFlag = true
    }

    /// 엔진 정지(일시정지·전환·종료 직전): 현재 녹음 파트를 닫는다. 세션은 유지.
    func engineStopped() {
        activeFlag = false
        guard isActive else { return }
        ioQ.async { [self] in audio.closePart() }
        refreshParts()
        saveAll()
    }

    private func beginSession() {
        let start = Date()
        sessionID = Self.folderName.string(from: start)
        let folder = sessionsRoot.appendingPathComponent(sessionID, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("audio"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("photos"), withIntermediateDirectories: true)
        } catch {
            lastError = "세션 폴더 생성 실패: \(error.localizedDescription)"
            FileLog.write("session folder failed: \(error)")
            return
        }
        isActive = true
        sessionStart = start
        sessionURL = folder
        lines = []
        parts = []
        audioSeconds = 0
        audioFileMB = 0
        dirty = false
        metricsHeaderWritten = false
        lastError = nil
        lastSavedAt = nil
        tick = 0
        let evalPath = ProcessInfo.processInfo.environment["LIVESUB_RECORD"]
        ioQ.async { [self] in
            audio.reset(folder: folder)
            evalWav = nil
            evalWavPath = evalPath
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick() }
        }
        writeManifest(ended: false)
        FileLog.write("session begin: \(folder.path)")
    }

    /// 세션 종료: 녹음을 닫고 session.json / transcript.json / transcript.md 를 마지막으로 저장.
    func endSession(reason: String) {
        guard isActive, let folder = sessionURL else { return }
        timer?.invalidate(); timer = nil
        isActive = false
        activeFlag = false
        FileLog.write("session end (\(reason)): \(folder.path)")

        let sem = DispatchSemaphore(value: 0)
        ioQ.async { [self] in
            audio.closePart()
            evalWav = nil
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 8)
        refreshParts()

        if lines.isEmpty && audioSeconds < 5 {
            ioQ.async { try? FileManager.default.removeItem(at: folder) }
            FileLog.write("session discarded (empty)")
            sessionURL = nil
            return
        }
        saveAll(force: true)
        writeManifest(ended: true)
    }

    /// "새 세션 시작": 현재 세션을 닫고 바로 새로 시작 (세션 모드에서만)
    func startNewSession() {
        guard mode == .session else { return }
        let wasActive = activeFlag
        endSession(reason: "새 세션")
        beginSession()
        activeFlag = wasActive
    }

    // MARK: 오디오 (탭 스레드에서 호출)

    nonisolated func write(_ buffer: AVAudioPCMBuffer) {
        guard activeFlag, let copy = buffer.deepCopy() else { return }
        ioQ.async { [self] in
            audio.write(copy)
            if let path = evalWavPath {
                if evalWav == nil {
                    evalWav = try? AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: copy.format.settings,
                                               commonFormat: copy.format.commonFormat, interleaved: copy.format.isInterleaved)
                    FileLog.write("eval recording to \(path): \(evalWav != nil)")
                }
                try? evalWav?.write(from: copy)
            }
        }
    }

    // MARK: 문장

    func addLine(id: UUID, startedAt: Date?, english: String, korean: String) {
        guard isActive else { return }
        let ended = Date()
        let started = startedAt ?? lines.last?.endedAt ?? ended
        let pos = ioQ.sync { audio.position }        // (파일, 파트 안 위치)
        let end = pos.seconds
        let start = max(0, end - ended.timeIntervalSince(started))
        let words = english.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        lines.append(TranscriptLine(id: id, index: lines.count, startedAt: started, endedAt: ended,
                                    audioFile: pos.file, audioStart: start, audioEnd: end,
                                    english: english, korean: korean, words: words))
        dirty = true
    }

    func updateKorean(id: UUID, korean: String) {
        guard let i = lines.lastIndex(where: { $0.id == id }) else { return }
        lines[i].korean = korean
        dirty = true
    }

    private func onTick() {
        tick += 1
        let (secs, mb, changed) = ioQ.sync { (audio.totalSeconds, audio.fileMB, audio.takeChanged()) }
        audioSeconds = secs
        audioFileMB = mb
        if changed { refreshParts(); writeManifest(ended: false) }
        if tick % 5 == 0 { saveAll() }           // 10초마다
    }

    private func refreshParts() {
        parts = ioQ.sync { audio.parts }
        audioSeconds = ioQ.sync { audio.totalSeconds }
    }

    // MARK: 저장

    private func saveAll(force: Bool = false) {
        guard isActive || force, dirty || force, let folder = sessionURL, !lines.isEmpty else { return }
        dirty = false
        let md = transcriptMarkdown()
        let doc = TranscriptDocument(sessionId: sessionID, segments: lines)
        let json = try? Self.encoder.encode(doc)
        ioQ.async {
            try? md.write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
            try? json?.write(to: folder.appendingPathComponent("transcript.json"), options: .atomic)
        }
        lastSavedAt = Date()
        writeManifest(ended: false)
    }

    private func writeManifest(ended: Bool) {
        guard let folder = sessionURL, let start = sessionStart else { return }
        let m = SessionManifest(id: sessionID, title: "LiveSubtitle \(Self.titleStamp.string(from: start))",
                                startedAt: start, endedAt: ended ? Date() : nil, timeZone: TimeZone.current.identifier,
                                engine: engineTitle, engineLagSeconds: engineLag, audio: parts,
                                sentences: lines.count, words: wordCount,
                                files: ["transcript": "transcript.json", "transcriptMarkdown": "transcript.md", "metrics": "metrics.csv", "photos": "photos.json"])
        guard let data = try? Self.encoder.encode(m) else { return }
        ioQ.async { try? data.write(to: folder.appendingPathComponent("session.json"), options: .atomic) }
    }

    private func transcriptMarkdown() -> String {
        let start = sessionStart ?? Date()
        var s = "# LiveSubtitle \(Self.titleStamp.string(from: start))\n\n"
        s += "- 시작: \(Self.fullStamp.string(from: start))\n"
        s += "- 엔진: \(engineTitle)\n"
        s += "- 문장: \(lines.count)개 · 단어: \(wordCount)개\n"
        s += "- 녹음: \(parts.count)개 파트, \(Self.clock(audioSeconds))  [시각 · 파트 위치]\n"
        s += "\n---\n\n"
        for l in lines {
            let part = l.audioFile.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".m4a", with: "") } ?? "-"
            s += "**[\(Self.timeOnly.string(from: l.endedAt)) · \(part) \(Self.clock(l.audioStart))]** \(l.korean.isEmpty ? "(번역 대기)" : l.korean)  \n"
            s += "EN: \(l.english)\n\n"
        }
        return s
    }

    // MARK: 메트릭 CSV (ResourceMonitor 표본마다 호출)

    func appendMetric(_ m: MetricSample, sentences: Int, words: Int, avgTranslateMs: Double) {
        guard isActive, let folder = sessionURL, let start = sessionStart else { return }
        let url = folder.appendingPathComponent("metrics.csv")
        var text = ""
        if !metricsHeaderWritten {
            metricsHeaderWritten = true
            text += "time,elapsed_s,app_cpu_pct,sys_cpu_pct,mem_mb,threads,power_w,thermal,sentences,words,avg_translate_ms,audio_s\n"
        }
        let power = m.powerW.map { String(format: "%.2f", $0) } ?? ""
        text += String(format: "%@,%.0f,%.1f,%.1f,%.1f,%d,%@,%d,%d,%d,%.0f,%.1f\n",
                       Self.isoStamp.string(from: m.t), m.t.timeIntervalSince(start), m.appCPU, m.sysCPU, m.memMB, m.threads,
                       power, m.thermalLevel, sentences, words, avgTranslateMs, audioSeconds)
        ioQ.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); try? h.close()
            } else {
                try? text.data(using: .utf8)!.write(to: url)
            }
        }
    }

    // MARK: 폴더 선택 / 열기

    func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "이 폴더에 저장"
        panel.message = "세션 폴더(녹음·전사·메트릭)를 저장할 위치"
        if !customPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: customPath) }
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            customPath = url.path
            location = .custom
        }
    }

    func revealSessionFolder() {
        if let u = sessionURL, FileManager.default.fileExists(atPath: u.path) {
            NSWorkspace.shared.activateFileViewerSelecting([u])
        } else {
            try? FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
            NSWorkspace.shared.open(sessionsRoot)
        }
    }

    // MARK: 포맷

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(iso.string(from: date))
        }
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let d = iso.date(from: s) ?? isoNoFrac.date(from: s) { return d }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()
    /// 절대 시각: 로컬 시간대 오프셋 + 소수점 초 (예: 2026-09-29T09:15:02.417+09:00)
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; f.timeZone = .current; return f
    }()
    static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; f.timeZone = .current; return f
    }()
    static let folderName: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH-mm-ss"; return f }()
    static let titleStamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f }()
    static let fullStamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()
    static let timeOnly: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    static let isoStamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f }()

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - 오디오 파트 쓰기 (AAC .m4a, 5초 조각 기록 → 앱이 비정상 종료돼도 마지막 조각만 잃음)

final class AudioWriter {
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var wavFallback: AVAudioFile?
    private var format: AVAudioFormat?
    private var folder: URL?
    private var partIndex = 0
    private var partFrames: Int64 = 0            // 현재 파트의 프레임 위치 (타임스탬프)
    private var closedSeconds: Double = 0        // 닫힌 파트들의 합계
    private var failed = false
    private var dropped = 0
    private var changed = false
    private(set) var parts: [AudioPart] = []

    static let fragmentSeconds = 5.0

    var partSeconds: Double {
        guard let f = format, f.sampleRate > 0 else { return 0 }
        return Double(partFrames) / f.sampleRate
    }
    var totalSeconds: Double { closedSeconds + (isOpen ? partSeconds : 0) }
    var isOpen: Bool { writer != nil || wavFallback != nil }
    /// 지금 이 순간의 (파트 파일, 파트 안 위치)
    var position: (file: String?, seconds: Double) { (isOpen ? parts.last?.file : nil, isOpen ? partSeconds : 0) }
    var fileMB: Double {
        guard let folder else { return 0 }
        return parts.reduce(0) { $0 + Double((try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent($1.file).path)[.size] as? Int) ?? 0) } / 1_048_576
    }
    func takeChanged() -> Bool { defer { changed = false }; return changed }

    func reset(folder: URL) {
        closePart()
        self.folder = folder
        partIndex = 0
        partFrames = 0
        closedSeconds = 0
        format = nil
        failed = false
        dropped = 0
        parts = []
        changed = false
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        guard let folder, !failed, buffer.frameLength > 0 else { return }
        if !isOpen || format != buffer.format {
            open(buffer.format, in: folder)
        }
        if let wav = wavFallback {
            do { try wav.write(from: buffer); partFrames += Int64(buffer.frameLength) }
            catch { FileLog.write("audio write failed: \(error)") }
            return
        }
        guard let writer, let input else { return }
        if writer.status == .failed {
            failed = true
            FileLog.write("audio writer failed: \(String(describing: writer.error))")
            return
        }
        // 실시간 입력에서는 거의 항상 준비 상태. 잠깐 기다려도 안 되면 이 버퍼(≈85ms)는 버림
        var waited = 0
        while !input.isReadyForMoreMediaData && waited < 10 { Thread.sleep(forTimeInterval: 0.005); waited += 1 }
        guard input.isReadyForMoreMediaData else {
            dropped += 1
            if dropped % 50 == 1 { FileLog.write("audio writer not ready, dropped \(dropped) buffers") }
            return
        }
        guard let sample = Self.sampleBuffer(buffer, at: partFrames) else { return }
        if input.append(sample) {
            partFrames += Int64(buffer.frameLength)
        } else {
            FileLog.write("audio append failed: \(String(describing: writer.error))")
        }
    }

    private func open(_ fmt: AVAudioFormat, in folder: URL) {
        closePart()
        partIndex += 1
        format = fmt
        partFrames = 0
        let name = String(format: "audio/part-%03d.m4a", partIndex)
        let url = folder.appendingPathComponent(name)
        let channels = Int(fmt.channelCount)
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .m4a)
            w.movieFragmentInterval = CMTime(seconds: Self.fragmentSeconds, preferredTimescale: 1)
            w.shouldOptimizeForNetworkUse = false
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: fmt.sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 64_000 * channels,
            ]
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: fmt.formatDescription)
            i.expectsMediaDataInRealTime = true
            guard w.canAdd(i) else { throw NSError(domain: "AudioWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "입력을 추가할 수 없음"]) }
            w.add(i)
            guard w.startWriting() else { throw w.error ?? NSError(domain: "AudioWriter", code: 2) }
            w.startSession(atSourceTime: .zero)
            writer = w
            input = i
            parts.append(AudioPart(file: name, startedAt: Date(), endedAt: nil, durationSeconds: 0, sampleRate: fmt.sampleRate, channels: channels))
            changed = true
            FileLog.write("audio recording → \(name) \(fmt) (AAC, \(Int(Self.fragmentSeconds))초 조각)")
        } catch {
            // AAC를 못 만들면(드문 포맷) 무압축 WAV로
            let wavName = String(format: "audio/part-%03d.wav", partIndex)
            let wav = folder.appendingPathComponent(wavName)
            do {
                wavFallback = try AVAudioFile(forWriting: wav, settings: fmt.settings, commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
                parts.append(AudioPart(file: wavName, startedAt: Date(), endedAt: nil, durationSeconds: 0, sampleRate: fmt.sampleRate, channels: channels))
                changed = true
                FileLog.write("audio recording (wav fallback) → \(wavName): AAC failed \(error)")
            } catch {
                failed = true
                FileLog.write("audio recording failed: \(error)")
            }
        }
    }

    /// 현재 파트 마무리 (헤더 완성). 동기적으로 최대 5초 대기.
    func closePart() {
        guard isOpen else { return }
        let secs = partSeconds
        if !parts.isEmpty {
            parts[parts.count - 1].endedAt = Date()
            parts[parts.count - 1].durationSeconds = secs
        }
        closedSeconds += secs
        partFrames = 0
        changed = true
        wavFallback = nil
        if let w = writer {
            let i = input
            writer = nil
            input = nil
            if w.status == .writing {
                i?.markAsFinished()
                let sem = DispatchSemaphore(value: 0)
                w.finishWriting { sem.signal() }
                if sem.wait(timeout: .now() + 5) == .timedOut { FileLog.write("audio finishWriting timed out") }
                if w.status != .completed { FileLog.write("audio finishWriting status=\(w.status.rawValue) \(String(describing: w.error))") }
            }
        }
    }

    /// AVAudioPCMBuffer → CMSampleBuffer (데이터는 복사됨)
    private static func sampleBuffer(_ pcm: AVAudioPCMBuffer, at frame: Int64) -> CMSampleBuffer? {
        let rate = CMTimeScale(pcm.format.sampleRate)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: rate),
                                        presentationTimeStamp: CMTime(value: frame, timescale: rate),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: pcm.format.formatDescription, sampleCount: CMItemCount(pcm.frameLength),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sb) == noErr, let sb else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sb, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                             flags: 0, bufferList: pcm.audioBufferList) == noErr else { return nil }
        return sb
    }
}

extension AVAudioPCMBuffer {
    /// 탭 버퍼는 콜백 뒤 재사용되므로 다른 스레드로 넘길 때 복사
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let c = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        c.frameLength = frameLength
        // 인터리브 포맷은 채널 0 포인터 하나에 frame×channel 개가 이어져 있음
        let ch = format.isInterleaved ? 1 : Int(format.channelCount)
        let n = Int(frameLength) * (format.isInterleaved ? Int(format.channelCount) : 1)
        if let src = floatChannelData, let dst = c.floatChannelData {
            for i in 0..<ch { dst[i].update(from: src[i], count: n) }
        } else if let src = int16ChannelData, let dst = c.int16ChannelData {
            for i in 0..<ch { dst[i].update(from: src[i], count: n) }
        } else if let src = int32ChannelData, let dst = c.int32ChannelData {
            for i in 0..<ch { dst[i].update(from: src[i], count: n) }
        } else { return nil }
        return c
    }
}
