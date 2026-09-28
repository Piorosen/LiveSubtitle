import SwiftUI
import Charts
import AVFoundation
import AppKit

// MARK: - 저장된 세션 읽기

/// 세션 목록 항목 (session.json 또는 이전 형식 transcript.md 에서)
struct SessionSummary: Identifiable, Equatable {
    let id: String              // 폴더 이름
    let url: URL
    let title: String
    let startedAt: Date
    let endedAt: Date?
    let durationSeconds: Double
    let sentences: Int
    let words: Int
    let audioMB: Double
    let engine: String
    let legacy: Bool            // 이전 형식(폴더 바로 아래 audio.m4a / transcript.md)
    let inICloud: Bool
    let live: Bool              // 지금 기록 중인 세션
}

/// 세션 상세 (파일에서 읽음)
struct SessionDetail {
    var summary: SessionSummary
    var segments: [TranscriptLine]
    var parts: [AudioPart]
    var metrics: [MetricRow]
    var photos: [PhotoMatch]
    var lag: Double                  // 발화 → 확정 텍스트 추정 지연 (사진 매칭에 사용)

    struct MetricRow: Identifiable {
        let elapsed: Double
        let t: Date
        let appCPU, sysCPU, memMB: Double
        let powerW: Double?
        let words: Int
        var id: Double { elapsed }
    }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var roots: [URL] = []

    func reload(recorder: SessionRecorder) {
        var roots = [recorder.sessionsRoot]
        if let ic = SessionRecorder.iCloudSessions { roots.append(ic) }
        roots.append(SessionRecorder.documentsSessions)
        if let c = recorder.customSessions { roots.append(c) }
        if let c = recorder.customRoot { roots.append(c) }          // 이전 형식(폴더 바로 아래 transcript.md)
        var seen = Set<String>()
        self.roots = roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
        let liveURL = recorder.isActive ? recorder.sessionURL : nil
        let icloudPath = Storage.iCloudRoot?.standardizedFileURL.path
        let found = self.roots.flatMap { Self.scan($0, liveURL: liveURL, icloudPath: icloudPath) }
        sessions = found.sorted { $0.startedAt > $1.startedAt }
    }

    private static func scan(_ root: URL, liveURL: URL?, icloudPath: String?) -> [SessionSummary] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return items.compactMap { dir in
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let inICloud = icloudPath.map { dir.standardizedFileURL.path.hasPrefix($0) } ?? false
            let live = liveURL.map { $0.standardizedFileURL.path == dir.standardizedFileURL.path } ?? false
            if let s = loadManifest(dir, inICloud: inICloud, live: live) { return s }
            return loadLegacy(dir, inICloud: inICloud)
        }
    }

    private static func loadManifest(_ dir: URL, inICloud: Bool, live: Bool) -> SessionSummary? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
              let m = try? SessionRecorder.decoder.decode(SessionManifest.self, from: data) else { return nil }
        let duration = m.audio.reduce(0) { $0 + $1.durationSeconds }
        let mb = m.audio.reduce(0.0) { $0 + fileMB(dir.appendingPathComponent($1.file)) }
        let wall = (m.endedAt ?? Date()).timeIntervalSince(m.startedAt)
        return SessionSummary(id: dir.lastPathComponent, url: dir, title: m.title, startedAt: m.startedAt, endedAt: m.endedAt,
                              durationSeconds: duration > 0 ? duration : wall, sentences: m.sentences, words: m.words, audioMB: mb,
                              engine: m.engine, legacy: false, inICloud: inICloud, live: live)
    }

    /// 이전 형식: transcript.md 헤더에서 시작 시각·문장 수, audio.m4a 길이
    private static func loadLegacy(_ dir: URL, inICloud: Bool) -> SessionSummary? {
        let md = dir.appendingPathComponent("transcript.md")
        let audio = dir.appendingPathComponent("audio.m4a")
        guard FileManager.default.fileExists(atPath: md.path) || FileManager.default.fileExists(atPath: audio.path) else { return nil }
        let text = (try? String(contentsOf: md, encoding: .utf8)) ?? ""
        let (seg, start, engine) = parseLegacyMarkdown(text, folder: dir.lastPathComponent)
        var duration = seg.last?.audioEnd ?? 0
        if let f = try? AVAudioFile(forReading: audio) { duration = Double(f.length) / f.fileFormat.sampleRate }
        let started = start ?? SessionRecorder.folderName.date(from: dir.lastPathComponent) ?? Date.distantPast
        return SessionSummary(id: dir.lastPathComponent, url: dir, title: "LiveSubtitle \(SessionRecorder.titleStamp.string(from: started))",
                              startedAt: started, endedAt: started.addingTimeInterval(duration), durationSeconds: duration,
                              sentences: seg.count, words: seg.reduce(0) { $0 + $1.words }, audioMB: fileMB(audio),
                              engine: engine, legacy: true, inICloud: inICloud, live: false)
    }

    /// `**[HH:mm:ss · mm:ss]** 한국어` + `EN: 영어` 형식
    static func parseLegacyMarkdown(_ text: String, folder: String) -> ([TranscriptLine], Date?, String) {
        var start: Date?
        var engine = ""
        var lines: [TranscriptLine] = []
        let day = SessionRecorder.folderName.date(from: folder) ?? Date()
        let cal = Calendar.current
        var pendingKO: (Date, Double, String)?
        for raw in text.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("- 시작: ") { start = SessionRecorder.fullStamp.date(from: String(l.dropFirst("- 시작: ".count))) }
            else if l.hasPrefix("- 엔진: ") { engine = String(l.dropFirst("- 엔진: ".count)) }
            else if l.hasPrefix("**["), let close = l.range(of: "]**") {
                let stamp = String(l[l.index(l.startIndex, offsetBy: 3)..<close.lowerBound])
                let ko = String(l[close.upperBound...]).trimmingCharacters(in: .whitespaces)
                let comps = stamp.components(separatedBy: " · ")
                var at = day
                if let t = SessionRecorder.timeOnly.date(from: comps[0]) {
                    let tc = cal.dateComponents([.hour, .minute, .second], from: t)
                    at = cal.date(bySettingHour: tc.hour ?? 0, minute: tc.minute ?? 0, second: tc.second ?? 0, of: day) ?? day
                    if let s = start, at < s { at = cal.date(byAdding: .day, value: 1, to: at) ?? at }   // 자정 넘김
                }
                var off = 0.0
                if comps.count > 1 {
                    let p = comps[1].components(separatedBy: ":").compactMap { Double($0) }
                    if p.count == 2 { off = p[0] * 60 + p[1] } else if p.count == 3 { off = p[0] * 3600 + p[1] * 60 + p[2] }
                }
                pendingKO = (at, off, ko)
            } else if let (at, off, ko) = pendingKO, let colon = l.firstIndex(of: ":"), l.distance(from: l.startIndex, to: colon) <= 7,
                      l[..<colon].allSatisfy({ $0.isUppercase || $0 == "-" }), l[l.index(after: colon)...].hasPrefix(" ") {
                let en = String(l[l.index(colon, offsetBy: 2)...])
                let words = en.split(separator: " ").count
                let prevEnd = lines.last?.endedAt ?? at.addingTimeInterval(-4)
                lines.append(TranscriptLine(id: UUID(), index: lines.count, startedAt: prevEnd, endedAt: at, audioFile: "audio.m4a",
                                            audioStart: max(0, off - at.timeIntervalSince(prevEnd)), audioEnd: off,
                                            source: en, target: ko == "(번역 대기)" ? "" : ko, words: words))
                pendingKO = nil
            }
        }
        return (lines, start, engine)
    }

    static func loadDetail(_ s: SessionSummary) -> SessionDetail {
        var segments: [TranscriptLine] = []
        var parts: [AudioPart] = []
        var lag = 5.0
        if s.legacy {
            let text = (try? String(contentsOf: s.url.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
            segments = parseLegacyMarkdown(text, folder: s.id).0
            parts = [AudioPart(file: "audio.m4a", startedAt: s.startedAt, endedAt: s.endedAt, durationSeconds: s.durationSeconds, sampleRate: 48000, channels: 1)]
        } else {
            if let data = try? Data(contentsOf: s.url.appendingPathComponent("transcript.json")),
               let doc = try? SessionRecorder.decoder.decode(TranscriptDocument.self, from: data) { segments = doc.segments }
            if let data = try? Data(contentsOf: s.url.appendingPathComponent("session.json")),
               let m = try? SessionRecorder.decoder.decode(SessionManifest.self, from: data) { parts = m.audio; lag = m.engineLagSeconds }
        }
        let photos = PhotoImporter.load(s.url)?.photos ?? []
        return SessionDetail(summary: s, segments: segments, parts: parts, metrics: loadMetrics(s.url.appendingPathComponent("metrics.csv"), start: s.startedAt),
                             photos: photos, lag: lag)
    }

    private static func loadMetrics(_ url: URL, start: Date) -> [SessionDetail.MetricRow] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var rows: [SessionDetail.MetricRow] = []
        var idx: [String: Int] = [:]
        for (n, line) in text.split(separator: "\n").enumerated() {
            let c = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if n == 0 { for (i, h) in c.enumerated() { idx[h] = i }; continue }
            func d(_ k: String) -> Double? { idx[k].flatMap { $0 < c.count ? Double(c[$0]) : nil } }
            guard let el = d("elapsed_s") else { continue }
            rows.append(.init(elapsed: el, t: start.addingTimeInterval(el), appCPU: d("app_cpu_pct") ?? 0, sysCPU: d("sys_cpu_pct") ?? 0,
                              memMB: d("mem_mb") ?? 0, powerW: d("power_w"), words: Int(d("words") ?? 0)))
        }
        return rows
    }

    private static func fileMB(_ url: URL) -> Double {
        Double((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 1_048_576
    }
}

// MARK: - 재생

@MainActor
final class SessionPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var currentFile: String?
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL, file: String) {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        p.prepareToPlay()
        player = p
        currentFile = file
        duration = p.duration
        currentTime = 0
    }

    func play(from seconds: Double? = nil) {
        guard let p = player else { return }
        if let s = seconds { p.currentTime = max(0, min(s, p.duration)) }
        p.play()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, let p = self.player else { return }; self.currentTime = p.currentTime }
        }
    }
    func pause() { player?.pause(); isPlaying = false; timer?.invalidate() }
    func toggle() { isPlaying ? pause() : play() }
    func seek(_ s: Double) { player?.currentTime = s; currentTime = s }
    func stop() { player?.stop(); player = nil; isPlaying = false; timer?.invalidate(); currentTime = 0; duration = 0; currentFile = nil }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.isPlaying = false; self.timer?.invalidate() }
    }
}

// MARK: - 세션 보기 창

struct SessionBrowserView: View {
    @ObservedObject var recorder: SessionRecorder
    var initialSelection: String? = nil        // 열 때 선택할 세션 폴더 이름 (예: 지금 기록 중인 세션)
    var initialPage = "transcript"             // "transcript" | "charts"
    @StateObject private var store = SessionStore()
    @StateObject private var player = SessionPlayer()
    @StateObject private var importer = PhotoImporter()
    @State private var selection: String?
    @State private var detail: SessionDetail?
    @State private var page = "transcript"
    @State private var query = ""
    @State private var exportStatus = ""
    @AppStorage("pptx.includeEnglish") private var pptxEnglish = true

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("세션 \(store.sessions.count)개") {
                    ForEach(store.sessions) { s in
                        row(s).tag(s.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .toolbar {
                ToolbarItem { Button { reload() } label: { Label("새로 고침", systemImage: "arrow.clockwise") } }
                ToolbarItem { Button { NSWorkspace.shared.open(recorder.sessionsRoot) } label: { Label("폴더 열기", systemImage: "folder") } }
            }
        } detail: {
            if let d = detail { detailView(d) }
            else {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.and.magnifyingglass").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("왼쪽에서 세션을 선택하세요").foregroundStyle(.secondary)
                    Text(recorder.mode == .session ? "세션 모드로 기록 중인 세션은 목록 맨 위에 ● 표시됩니다." : "메뉴바 또는 자막 창의 '세션 시작'을 누르면 녹음·전사가 저장됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .onAppear {
            page = initialPage
            reload()
            if selection == nil, let want = initialSelection ?? store.sessions.first?.id, store.sessions.contains(where: { $0.id == want }) {
                selection = want
            }
        }
        .onChange(of: selection) { _, id in
            player.stop()
            detail = store.sessions.first { $0.id == id }.map { SessionStore.loadDetail($0) }
        }
        .onReceive(recorder.$lines) { lines in
            // 기록 중인 세션을 보고 있으면 파일(10초마다 저장)을 기다리지 않고 메모리의 문장을 바로 반영
            if var d = detail, d.summary.live { d.segments = lines; d.parts = recorder.parts; detail = d }
        }
    }

    private func reload() {
        store.reload(recorder: recorder)
        if let id = selection, let s = store.sessions.first(where: { $0.id == id }) { detail = SessionStore.loadDetail(s) }
    }

    private func row(_ s: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if s.live { Circle().fill(.red).frame(width: 7, height: 7) }
                Text(SessionRecorder.titleStamp.string(from: s.startedAt)).font(.body.weight(.medium))
                Spacer()
                if s.inICloud { Image(systemName: "icloud").font(.caption).foregroundStyle(.secondary) }
            }
            Text("\(SessionRecorder.clock(s.durationSeconds)) · 문장 \(s.sentences) · \(s.words) 단어" + (s.legacy ? " · 이전 형식" : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: 상세

    private func detailView(_ d: SessionDetail) -> some View {
        let s = d.summary
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.title2.bold())
                    Text("\(SessionRecorder.fullStamp.string(from: s.startedAt))" + (s.endedAt.map { " → \(SessionRecorder.timeOnly.string(from: $0))" } ?? " → 기록 중")
                         + " · \(s.engine)" + (s.inICloud ? " · iCloud Drive" : "")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await importPhotos(d) } } label: { Label(d.photos.isEmpty ? "사진 가져오기 (Photos)" : "사진 다시 찾기", systemImage: "photo.on.rectangle") }
                    .disabled(importer.busy)
                    .help("세션 시간 범위(앞뒤 5분)의 사진을 Photos에서 찾아 photos/ 에 복사하고 촬영 시각으로 문장에 붙입니다. 처음엔 사진 보관함 권한 창이 뜹니다.")
                Menu {
                    Toggle("영어 원문 포함", isOn: $pptxEnglish)
                    Divider()
                    Button("pptx로 내보내기…") { exportPptx(d) }
                } label: { Label("pptx", systemImage: "rectangle.on.rectangle.angled") }
                .menuStyle(.borderedButton).fixedSize()
                .help("사진 한 장 = 슬라이드 하나(앵커 문장부터 다음 사진 앵커 전까지의 텍스트), 사진이 없으면 텍스트만. 문장이 많으면 같은 사진을 유지한 채 이어지는 슬라이드로 나뉩니다.")
                Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([s.url]) }
                Button("전사 열기") { NSWorkspace.shared.open(s.url.appendingPathComponent("transcript.md")) }
            }
            if !importer.status.isEmpty || !exportStatus.isEmpty {
                HStack(spacing: 6) {
                    if importer.busy { ProgressView().controlSize(.small) }
                    Text([importer.status, exportStatus].filter { !$0.isEmpty }.joined(separator: "  ·  ")).font(.caption)
                        .foregroundStyle(importer.status.contains("거부") || importer.status.contains("없음") || exportStatus.hasPrefix("실패") ? .red : .secondary)
                }
            }
            tiles(d)
            playerBar(d)
            Picker("", selection: $page) {
                Text("자막 타임라인").tag("transcript")
                Text("사진 (\(d.photos.filter { !$0.excluded }.count))").tag("photos")
                Text("그래프").tag("charts")
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 360)
            switch page {
            case "photos": photosPage(d)
            case "charts": charts(d)
            default: transcriptList(d)
            }
        }
        .padding(16)
    }

    private func tiles(_ d: SessionDetail) -> some View {
        let s = d.summary
        let mins = max(1, s.durationSeconds / 60)
        let avgCPU = d.metrics.isEmpty ? nil : d.metrics.reduce(0) { $0 + $1.appCPU } / Double(d.metrics.count)
        let pw = d.metrics.compactMap(\.powerW)
        let avgPower = pw.isEmpty ? nil : pw.reduce(0, +) / Double(pw.count)
        return HStack(spacing: 10) {
            tile("길이", SessionRecorder.clock(s.durationSeconds), d.parts.count > 1 ? "\(d.parts.count)개 파트" : "")
            tile("문장", "\(s.sentences)", "")
            tile("단어", "\(s.words)", String(format: "%.0f/분", Double(s.words) / mins))
            tile("녹음", String(format: "%.1f", s.audioMB), "MB")
            tile("사진", "\(d.photos.filter { !$0.excluded }.count)", d.photos.contains { $0.excluded } ? "+\(d.photos.filter(\.excluded).count) 제외" : "")
            tile("앱 CPU 평균", avgCPU.map { String(format: "%.1f", $0) } ?? "—", "%")
            tile("시스템 전력 평균", avgPower.map { String(format: "%.1f", $0) } ?? "—", avgPower == nil ? "전원 연결" : "W")
        }
    }

    private func tile(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text(unit).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func playerBar(_ d: SessionDetail) -> some View {
        HStack(spacing: 10) {
            Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 14) }
                .disabled(player.currentFile == nil)
                .help(player.currentFile == nil ? "자막 줄을 클릭하면 그 위치부터 재생합니다" : "재생/일시정지")
            Text(player.currentFile.map { ($0 as NSString).lastPathComponent } ?? "재생할 파트: 자막 줄을 클릭").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek($0) }), in: 0...max(1, player.duration))
                .disabled(player.currentFile == nil)
            Text("\(SessionRecorder.clock(player.currentTime)) / \(SessionRecorder.clock(player.duration))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    // MARK: 자막 타임라인

    private func transcriptList(_ d: SessionDetail) -> some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = q.isEmpty ? d.segments : d.segments.filter { $0.source.lowercased().contains(q) || $0.target.lowercased().contains(q) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("자막 검색 (원문·번역)", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Text("\(rows.count)개 문장").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { l in
                        Button { play(l, in: d) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(SessionRecorder.timeOnly.string(from: l.endedAt)).font(.caption.monospacedDigit())
                                    Text(SessionRecorder.clock(l.audioStart)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                .frame(width: 64, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(l.target.isEmpty ? "(번역 없음)" : l.target).font(.body)
                                    Text(l.source).font(.callout).foregroundStyle(.secondary)
                                    let ph = d.photos.filter { $0.segmentIndex == l.index }
                                    if !ph.isEmpty {
                                        HStack(spacing: 6) {
                                            ForEach(ph) { p in thumb(p, in: d, height: 56) }
                                        }
                                        .padding(.top, 4)
                                    }
                                }
                                Spacer(minLength: 0)
                                if player.currentFile == l.audioFile, player.currentTime >= l.audioStart, player.currentTime < l.audioEnd + 0.5 {
                                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.blue).font(.caption)
                                }
                            }
                            .padding(.vertical, 6).padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
    }

    private func play(_ l: TranscriptLine, in d: SessionDetail) {
        guard let file = l.audioFile else { return }
        let url = d.summary.url.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if player.currentFile != file { player.load(url, file: file) }
        player.play(from: l.audioStart)
    }

    // MARK: pptx

    private func exportPptx(_ d: SessionDetail) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(d.summary.title).pptx"
        panel.allowedContentTypes = [.init(filenameExtension: "pptx") ?? .data]
        panel.directoryURL = d.summary.url
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var detailForExport = d
        if d.summary.live { detailForExport.segments = recorder.lines }
        do {
            var opt = PptxExporter.Options()
            opt.includeEnglish = pptxEnglish
            let n = try PptxExporter.export(detail: detailForExport, to: url, options: opt)
            exportStatus = "pptx 저장됨: 슬라이드 \(n)장 → \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            exportStatus = "실패: \(error.localizedDescription)"
        }
    }

    // MARK: 사진

    private func importPhotos(_ d: SessionDetail) async {
        let segs = d.summary.live ? recorder.lines : d.segments
        if case .success(let doc) = await importer.importPhotos(session: d.summary, segments: segs, lag: d.lag), var cur = detail {
            cur.photos = doc.photos
            detail = cur
        }
    }

    /// 사진 조정(앵커 이동·제외)을 photos.json에 저장
    private func updatePhoto(_ id: String, in d: SessionDetail, _ change: (inout PhotoMatch) -> Void) {
        guard var doc = PhotoImporter.load(d.summary.url), let i = doc.photos.firstIndex(where: { $0.id == id }) else { return }
        change(&doc.photos[i])
        PhotoImporter.save(doc, to: d.summary.url)
        if var cur = detail { cur.photos = doc.photos; detail = cur }
    }

    private func thumb(_ p: PhotoMatch, in d: SessionDetail, height: CGFloat) -> some View {
        ThumbView(url: d.summary.url.appendingPathComponent(p.thumb), height: height)
            .opacity(p.excluded ? 0.35 : 1)
            .overlay(alignment: .bottomTrailing) {
                if p.excluded { Text("제외").font(.caption2).padding(2).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.white).padding(2) }
            }
            .help("\(SessionRecorder.fullStamp.string(from: p.capturedAt)) 촬영" + (p.distanceSeconds > 0 ? String(format: " · 앵커 문장과 %.0f초 차이", p.distanceSeconds) : " · 문장 발화 중 촬영"))
            .contextMenu {
                Text(SessionRecorder.fullStamp.string(from: p.capturedAt))
                Button("이전 문장에 붙이기") { updatePhoto(p.id, in: d) { $0.segmentIndex = max(0, ($0.segmentIndex ?? 0) - 1) } }
                    .disabled((p.segmentIndex ?? 0) <= 0)
                Button("다음 문장에 붙이기") { updatePhoto(p.id, in: d) { $0.segmentIndex = min(d.segments.count - 1, ($0.segmentIndex ?? -1) + 1) } }
                    .disabled(d.segments.isEmpty || (p.segmentIndex ?? -1) >= d.segments.count - 1)
                Button("촬영 시각으로 다시 맞추기") {
                    updatePhoto(p.id, in: d) { m in let a = PhotoImporter.anchor(for: m.capturedAt, segments: d.segments, lag: d.lag); m.segmentIndex = a.index; m.distanceSeconds = a.distance }
                }
                Divider()
                Button(p.excluded ? "제외 취소" : "제외") { updatePhoto(p.id, in: d) { $0.excluded.toggle() } }
                Button("원본 파일 보기") { NSWorkspace.shared.activateFileViewerSelecting([d.summary.url.appendingPathComponent(p.file)]) }
            }
    }

    /// 사진 기준으로 문장을 묶은 슬라이드 미리보기 (pptx 구성과 같은 규칙)
    private func photosPage(_ d: SessionDetail) -> some View {
        let groups = PhotoImporter.groups(photos: d.photos, segments: d.segments)
        let unanchored = d.photos.filter { !$0.excluded && $0.segmentIndex == nil }
        let excluded = d.photos.filter(\.excluded)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if d.photos.isEmpty {
                    Text("아직 가져온 사진이 없습니다. 위의 '사진 가져오기'를 누르면 세션 시간 범위의 사진을 Photos에서 찾아 촬영 시각으로 문장에 붙입니다.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("사진 한 장(같은 문장에 붙은 여러 장은 함께)이 슬라이드 하나, 그 사진의 앵커 문장부터 다음 사진 앵커 전까지가 그 슬라이드의 텍스트입니다. 첫 사진 앞의 문장은 텍스트만. 썸네일을 오른쪽 클릭하면 문장을 옮기거나 제외할 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(groups.enumerated()), id: \.offset) { k, g in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 12) {
                            if g.photos.isEmpty {
                                Text("텍스트만").font(.caption).foregroundStyle(.secondary).frame(width: 160, alignment: .leading)
                            } else {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(g.photos) { p in thumb(p, in: d, height: 120) }
                                    Text(SessionRecorder.timeOnly.string(from: g.photos[0].capturedAt) + " 촬영").font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(width: 160, alignment: .leading)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("슬라이드 \(k + 1) · 문장 \(g.segments.count)개" + (g.segments.first.map { " · \(SessionRecorder.timeOnly.string(from: $0.endedAt))~" } ?? ""))
                                    .font(.caption.bold()).foregroundStyle(.secondary)
                                ForEach(g.segments) { l in
                                    Text(l.target.isEmpty ? l.source : l.target).font(.callout)
                                }
                                if g.segments.isEmpty { Text("(이 사진 뒤에 확정된 문장 없음)").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
                }
                if !unanchored.isEmpty {
                    Text("문장과 맞추지 못한 사진 (전사가 없는 세션)").font(.headline)
                    HStack(spacing: 8) { ForEach(unanchored) { p in thumb(p, in: d, height: 80) } }
                }
                if !excluded.isEmpty {
                    Text("제외한 사진 \(excluded.count)장 (오른쪽 클릭 > 제외 취소)").font(.headline)
                    HStack(spacing: 8) { ForEach(excluded) { p in thumb(p, in: d, height: 60) } }
                }
            }
        }
    }

    // MARK: 그래프

    private func charts(_ d: SessionDetail) -> some View {
        let wpm = wordsPerMinute(d)
        let m = downsample(d.metrics, to: 600)
        let hasPower = m.contains { $0.powerW != nil }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                chartCard("말하기 밀도 (분당 확정 단어 수)", note: "1분 구간마다 확정된 영어 단어 수. 비어 있는 구간은 쉬는 시간·일시정지.") {
                    Chart(wpm, id: \.minute) { p in
                        RectangleMark(xStart: .value("분", Double(p.minute) + 0.1), xEnd: .value("분", Double(p.minute) + 0.9),
                                      yStart: .value("단어", 0), yEnd: .value("단어", p.words))
                            .foregroundStyle(ChartPalette.blue).cornerRadius(2)
                    }
                    .chartXAxisLabel("세션 경과 (분)", alignment: .trailing)
                }
                if m.isEmpty {
                    Text("metrics.csv 가 없어 자원 그래프를 그릴 수 없습니다.").font(.caption).foregroundStyle(.secondary)
                } else {
                    chartCard("CPU 사용률 (%)", note: "앱은 코어 1개 = 100%, 시스템은 전체 코어 기준") {
                        Chart(m) { r in
                            LineMark(x: .value("분", r.elapsed / 60), y: .value("CPU", r.appCPU), series: .value("계열", "앱"))
                                .foregroundStyle(by: .value("계열", "앱")).lineStyle(ChartPalette.line)
                            LineMark(x: .value("분", r.elapsed / 60), y: .value("CPU", r.sysCPU), series: .value("계열", "시스템"))
                                .foregroundStyle(by: .value("계열", "시스템")).lineStyle(ChartPalette.line)
                        }
                        .chartForegroundStyleScale(["앱": ChartPalette.blue, "시스템": ChartPalette.orange])
                        .chartLegend(position: .top, alignment: .leading)
                        .chartXAxisLabel("세션 경과 (분)", alignment: .trailing)
                    }
                    chartCard("메모리 (MB)", note: nil) {
                        Chart(m) { r in
                            AreaMark(x: .value("분", r.elapsed / 60), y: .value("MB", r.memMB)).foregroundStyle(ChartPalette.aqua.opacity(0.18))
                            LineMark(x: .value("분", r.elapsed / 60), y: .value("MB", r.memMB)).foregroundStyle(ChartPalette.aqua).lineStyle(ChartPalette.line)
                        }
                        .chartXAxisLabel("세션 경과 (분)", alignment: .trailing)
                    }
                    chartCard("시스템 소비 전력 (W)", note: hasPower ? "배터리 순간 전류×전압 (맥 전체)" : "전원에 연결된 상태라 측정값이 없습니다.") {
                        Chart(m.compactMap { r in r.powerW.map { (e: r.elapsed, w: $0) } }, id: \.e) { p in
                            LineMark(x: .value("분", p.e / 60), y: .value("W", p.w)).foregroundStyle(ChartPalette.yellow).lineStyle(ChartPalette.line)
                        }
                        .chartXAxisLabel("세션 경과 (분)", alignment: .trailing)
                    }
                }
            }
        }
    }

    private func chartCard<C: View>(_ title: String, note: String?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content().frame(height: 150)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
    }

    private func wordsPerMinute(_ d: SessionDetail) -> [(minute: Int, words: Int)] {
        let start = d.summary.startedAt
        let total = Int(max(d.summary.durationSeconds, (d.summary.endedAt ?? Date()).timeIntervalSince(start)) / 60) + 1
        var bins = Array(repeating: 0, count: max(1, min(total, 24 * 60)))
        for l in d.segments {
            let m = Int(l.endedAt.timeIntervalSince(start) / 60)
            if m >= 0 && m < bins.count { bins[m] += l.words }
        }
        return bins.enumerated().map { (minute: $0.offset, words: $0.element) }
    }

    private func downsample(_ rows: [SessionDetail.MetricRow], to limit: Int) -> [SessionDetail.MetricRow] {
        let k = Int(ceil(Double(rows.count) / Double(limit)))
        guard k > 1 else { return rows }
        return stride(from: 0, to: rows.count, by: k).map { s in
            let g = rows[s..<min(s + k, rows.count)]
            let n = Double(g.count)
            let pw = g.compactMap(\.powerW)
            return .init(elapsed: g[g.startIndex].elapsed, t: g[g.startIndex].t,
                         appCPU: g.reduce(0) { $0 + $1.appCPU } / n, sysCPU: g.reduce(0) { $0 + $1.sysCPU } / n,
                         memMB: g.reduce(0) { $0 + $1.memMB } / n, powerW: pw.isEmpty ? nil : pw.reduce(0, +) / Double(pw.count),
                         words: g.last!.words)
        }
    }
}

/// 썸네일 파일을 비동기로 읽어 표시
struct ThumbView: View {
    let url: URL
    let height: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: height * 4 / 3)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) {
            let u = url
            image = await Task.detached(priority: .utility) { NSImage(contentsOf: u) }.value
        }
    }
}
