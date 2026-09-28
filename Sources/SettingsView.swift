import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var model: SubtitleModel
    @ObservedObject var resources: ResourceMonitor
    let app: AppDelegate
    @State private var tab: String

    init(model: SubtitleModel, resources: ResourceMonitor, app: AppDelegate, initialTab: String = "engine") {
        self.model = model
        self.resources = resources
        self.app = app
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            EngineTab(model: model).tabItem { Label("엔진", systemImage: "cpu") }.tag("engine")
            SubtitleTab(model: model, app: app).tabItem { Label("자막", systemImage: "captions.bubble") }.tag("subtitle")
            SessionTab(model: model, recorder: model.recorder, app: app).tabItem { Label("세션", systemImage: "record.circle") }.tag("session")
            ResourceTab(model: model, resources: resources).tabItem { Label("리소스", systemImage: "gauge.with.dots.needle.33percent") }.tag("resources")
            MetricsTab(model: model, resources: resources).tabItem { Label("메트릭", systemImage: "chart.xyaxis.line") }.tag("metrics")
            AboutTab(model: model).tabItem { Label("정보", systemImage: "info.circle") }.tag("about")
        }
        .frame(width: 760, height: 620)
    }
}

// MARK: - 엔진

struct EngineTab: View {
    @ObservedObject var model: SubtitleModel

    @ObservedObject private var languages: LanguageSupport
    @State private var pairStatus = ""

    init(model: SubtitleModel) {
        self.model = model
        self.languages = model.languages
    }

    var body: some View {
        Form {
            Section("언어") {
                Picker("말하는 언어", selection: Binding(get: { AppLanguage.named(model.sourceLanguage).code }, set: { model.setLanguages(source: $0) })) {
                    ForEach(AppLanguage.all) { l in
                        let ok = [EngineChoice.parakeetV2, .parakeetUltra, .apple].contains { languages.engineSupports($0, source: l.code) }
                        Text(ok ? "\(l.name)  (\(l.short))" : "\(l.name)  (\(l.short)) — 인식 엔진 없음").tag(l.code)
                    }
                }
                Picker("자막 언어", selection: Binding(get: { AppLanguage.named(model.targetLanguage).code }, set: { model.setLanguages(target: $0) })) {
                    ForEach(AppLanguage.all) { l in
                        let ok = languages.translationSupports(l.code) || AppLanguage.matches(l.code, model.sourceLanguage)
                        Text(ok ? "\(l.name)  (\(l.short))" : "\(l.name)  (\(l.short)) — 번역 미지원").tag(l.code)
                    }
                }
                LabeledContent("이 조합") {
                    Text(languages.pairStatus["\(model.sourceLanguage)>\(model.targetLanguage)"] ?? (model.needsTranslation ? "확인 중…" : "같은 언어 (번역 안 함)"))
                }
                Text("말하는 언어를 바꾸면 그 언어를 들을 수 있는 엔진으로 자동 전환됩니다: Parakeet v2 = 영어 전용, Parakeet Ultra = 유럽 25개 언어(자동 감지), Apple 내장 = 시스템이 지원하는 언어(한국어·일본어·중국어 등). 자막 언어는 Apple 번역이 지원하는 언어 중에서 고르며, 새 조합은 첫 번역 때 모델 다운로드 창이 뜹니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("음성 인식") {
                Picker("엔진", selection: Binding(get: { model.engineChoice }, set: { model.selectEngine($0) })) {
                    ForEach(EngineChoice.allCases) { c in
                        let ok = languages.engineSupports(c, source: model.sourceLanguage)
                        Text(ok ? c.title : "\(c.title) — \(AppLanguage.named(model.sourceLanguage).name) 미지원").tag(c)
                    }
                }
                .pickerStyle(.radioGroup)
                if model.engineChoice != .apple {
                    Picker("지연 / 정확도", selection: Binding(get: { model.latencyPreset }, set: { model.selectPreset($0) })) {
                        ForEach(LatencyPreset.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                }
                LabeledContent("상태") {
                    HStack(spacing: 6) {
                        Circle().fill(model.isListening ? Color.green : Color.orange).frame(width: 8, height: 8)
                        Text(model.paused ? "일시정지" : model.status).lineLimit(2)
                    }
                }
            }
            Section("번역 (Apple 기기 내 번역, \(AppLanguage.named(model.sourceLanguage).name) → \(AppLanguage.named(model.targetLanguage).name))") {
                LabeledContent("상태") {
                    HStack(spacing: 6) {
                        Circle().fill(model.translationReady ? Color.green : Color.orange).frame(width: 8, height: 8)
                        Text(model.translationStatus).lineLimit(2)
                    }
                }
                HStack {
                    Button("번역 모델 다운로드 창 열기") { model.requestModelDownload() }
                    Button("시스템 언어 설정 열기") { model.openLanguageSettings() }
                }
            }
            Section("엔진 비교 (이 맥에서 실측, EVAL.md)") {
                comparisonTable
            }
        }
        .formStyle(.grouped)
    }

    private var comparisonTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow {
                ForEach(["엔진", "크기", "WER 원본", "WER 원거리", "속도", "전력", "에너지/분", "지연"], id: \.self) {
                    Text($0).font(.caption.bold()).foregroundStyle(.secondary)
                }
            }
            ForEach(EngineCatalog.rows) { r in
                GridRow {
                    HStack(spacing: 4) {
                        if r.choice == model.engineChoice { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        Text(r.name)
                    }
                    Text(r.diskMB == 0 ? "내장" : "\(r.diskMB) MB")
                    Text(String(format: "%.1f%%", r.werClean))
                    Text(String(format: "%.1f%%", r.werFar)).fontWeight(.semibold)
                    Text(String(format: "%.0f×", r.rtfx))
                    Text(String(format: "%.1f W", r.powerW))
                    Text(String(format: "%.0f J", r.energyJPerMin))
                    Text(r.latency)
                }
                .font(.system(size: 12))
                .foregroundStyle(r.selectable ? .primary : .secondary)
                GridRow { Text(r.note).font(.caption).foregroundStyle(.secondary).gridCellColumns(8) }
            }
        }
    }
}

// MARK: - 자막

struct SubtitleTab: View {
    @ObservedObject var model: SubtitleModel
    let app: AppDelegate

    var body: some View {
        Form {
            Section("표시") {
                Slider(value: $model.fontSize, in: 16...80, step: 1) { Text("글자 크기  \(Int(model.fontSize))pt") }
                Slider(value: $model.opacity, in: 0.1...0.95) { Text("배경 불투명도  \(Int(model.opacity * 100))%") }
                Toggle("자막 창 위 컨트롤 줄 항상 표시 (끄면 마우스를 올릴 때만)", isOn: $model.alwaysShowControls)
                Toggle("원문(말하는 언어) 함께 표시 (⌘E)", isOn: $model.showSource)
                Toggle("직전 문장 흐리게 표시", isOn: $model.showPrevious)
            }
            Section("창") {
                HStack {
                    Button("자막 창 위치·크기 초기화") { app.resetOverlayPosition(nil) }
                    Button("자막 지우기 (⌘K)") { model.clear() }
                }
                Text("자막 창은 배경을 잡고 드래그해 옮기고, 가장자리를 끌어 크기를 바꿀 수 있습니다. 위치는 자동 저장됩니다. 숨기거나 다시 표시: 메뉴바 '자막' 아이콘, 또는 어디서나 ⌥⌘L.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 세션

struct SessionTab: View {
    @ObservedObject var model: SubtitleModel
    @ObservedObject var recorder: SessionRecorder
    let app: AppDelegate

    private var displayPath: String {
        recorder.sessionsRoot.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var body: some View {
        Form {
            Section("모드") {
                Picker("모드", selection: Binding(get: { recorder.mode }, set: { model.setMode($0) })) {
                    ForEach(AppMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text("기본 모드는 자막만 보여 주고 아무것도 저장하지 않습니다. 세션 모드는 아래 위치에 세션 폴더를 만들어 녹음(AAC, 5초 조각 기록), 문장별 절대 시각·녹음 위치가 붙은 전사(JSON·Markdown), 1초 간격 메트릭(CSV)을 계속 저장합니다. 자막 창의 빨간 pill, 메뉴바, ⌘R 로도 전환할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("저장 위치") {
                Picker("위치", selection: $recorder.location) {
                    ForEach(SaveLocation.allCases) { loc in Text(loc.title).tag(loc) }
                }
                .pickerStyle(.radioGroup)
                if recorder.location == .iCloud && Storage.iCloudRoot == nil {
                    Label(Storage.iCloudUnavailableReason, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if recorder.location == .custom {
                    HStack {
                        Text(recorder.customPath.isEmpty ? "(폴더를 선택하세요)" : recorder.customPath)
                            .font(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Button("폴더 선택…") { recorder.chooseCustomFolder() }
                    }
                }
                HStack {
                    Text(displayPath).font(.caption).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Finder에서 열기") { recorder.revealSessionFolder() }
                }
                Text("위치를 바꾸면 다음 세션부터 적용됩니다. iCloud Drive에 두면 iPhone·iPad·다른 맥의 파일 앱에서도 보입니다 (음성·텍스트가 이 맥 밖으로 나갑니다). 앱은 샌드박스 안에서 실행되므로 앱 폴더·iCloud 컨테이너·직접 고른 폴더 외에는 접근하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("세션 폴더 구조 (pptx 내보내기 · Photos 시간 매칭용)") {
                Text("""
session.json       세션 시각(시간대 포함), 엔진, 추정 인식 지연, 녹음 파트별 절대 시작 시각·길이
transcript.json    문장마다 startedAt / endedAt (절대 시각) + 녹음 파트·위치 + 영어·한국어·단어 수
transcript.md      사람이 읽는 전사
metrics.csv        1초 간격 CPU·메모리·전력·문장 수
audio/part-NNN.m4a 녹음 파트 (일시정지·엔진 전환마다 새 파트)
photos/            (예약) 나중에 Photos에서 촬영 시각으로 골라 넣을 사진
""").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }

            Section("현재 세션") {
                LabeledContent("상태", value: recorder.isActive ? (model.paused ? "일시정지 (녹음 파트 닫힘)" : "기록 중") : (recorder.mode == .session ? "준비 중" : "없음 (기본 모드)"))
                if let start = recorder.sessionStart {
                    LabeledContent("시작", value: SessionRecorder.fullStamp.string(from: start))
                }
                LabeledContent("녹음", value: String(format: "%@  ·  %d개 파트  ·  %.1f MB", SessionRecorder.clock(recorder.audioSeconds), recorder.parts.count, recorder.audioFileMB))
                LabeledContent("확정 문장", value: "\(recorder.lines.count)개  ·  \(recorder.wordCount) 단어")
                if let saved = recorder.lastSavedAt {
                    LabeledContent("마지막 저장", value: SessionRecorder.timeOnly.string(from: saved))
                }
                if let u = recorder.sessionURL {
                    HStack {
                        Text(u.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("세션 폴더 열기") { recorder.revealSessionFolder() }
                        Button("새 세션으로 나누기") { recorder.startNewSession() }
                    }
                }
                HStack {
                    Button("세션 보기…  (저장된 세션의 자막·그래프·재생)") { app.showSessions(nil) }
                }
                if let e = recorder.lastError {
                    Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 리소스

struct ResourceTab: View {
    @ObservedObject var model: SubtitleModel
    @ObservedObject var resources: ResourceMonitor

    var body: some View {
        Form {
            Section("이 앱") {
                LabeledContent("CPU 사용률", value: String(format: "%.1f %%  (코어 1개 = 100%%)", resources.processCPU))
                LabeledContent("메모리", value: String(format: "%.0f MB", resources.memoryMB))
                LabeledContent("스레드", value: "\(resources.threads)개")
                LabeledContent("음성 인식 모델 캐시", value: String(format: "%.0f MB  (앱 컨테이너의 Application Support/FluidAudio/Models)", resources.modelCacheMB))
                Text("Neural Engine 사용량은 macOS가 앱에 제공하지 않습니다. 엔진별 실측 전력은 엔진 탭의 표, 시간에 따른 변화는 메트릭 탭을 참고하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("시스템") {
                LabeledContent("전체 CPU 사용률", value: String(format: "%.0f %%", resources.systemCPU))
                LabeledContent("소비 전력", value: resources.powerW.map { String(format: "%.1f W  (맥 전체, 배터리 기준)", $0) } ?? "전원 연결 중에는 측정 불가")
                LabeledContent("열 상태", value: resources.thermal)
                LabeledContent("저전력 모드", value: resources.lowPower ? "켜짐" : "꺼짐")
                LabeledContent("배터리", value: resources.battery)
            }
            Section("이번 세션") {
                LabeledContent("경과 시간", value: model.stats.elapsedText)
                LabeledContent("확정 문장", value: "\(model.stats.sentences)개  ·  \(model.stats.words) 단어")
                LabeledContent("인식 결과 수신", value: "\(model.stats.asrUpdates)회")
                LabeledContent("평균 번역 지연", value: model.stats.avgTranslationMs > 0 ? String(format: "%.0f ms", model.stats.avgTranslationMs) : "-")
                LabeledContent("인식 엔진 재시작", value: "\(model.stats.engineRestarts)회")
            }
            Section("로그") {
                HStack {
                    Text(FileLog.url.path).font(.caption).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("로그 열기") { NSWorkspace.shared.open(FileLog.url) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 정보

struct AboutTab: View {
    @ObservedObject var model: SubtitleModel
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LiveSubtitle").font(.title2.bold())
                        Text("실시간 다국어 자막 (\(model.languagePair)) · 버전 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                        Text("인식·번역은 모두 기기 내에서 처리됩니다. 세션 모드에서 저장 위치를 iCloud Drive로 둔 경우에만 파일이 iCloud로 올라갑니다.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("사용한 구성요소") {
                LabeledContent("음성 인식", value: "NVIDIA Parakeet TDT 0.6B v2 / Ultra (CC-BY-4.0) · FluidAudio (Apache 2.0) · Apple SpeechAnalyzer")
                LabeledContent("번역", value: "Apple Translation 프레임워크 (기기 내, 지원 언어 간 어느 조합이든)")
                LabeledContent("저장", value: "AVFoundation (AAC 조각 녹음) · Swift Charts (메트릭·세션 그래프)")
                LabeledContent("평가", value: "LibriSpeech test-other, powermetrics · 자세한 내용은 EVAL.md")
            }
            Section("단축키") {
                Text("⌥⌘L  자막 창 보이기/숨기기 (전역, 어떤 앱에서나)\n⌘R  세션 시작/종료      ⌘L  세션 보기      ⌘,  설정      ⌘P  일시정지/재개      ⌘K  자막 지우기\n⌘=  글자 크게      ⌘-  글자 작게      ⌘E  원문 표시      ⌘Q  종료")
                    .font(.system(size: 12, design: .monospaced))
            }
        }
        .formStyle(.grouped)
    }
}
