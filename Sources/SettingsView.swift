import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var model: SubtitleModel
    @ObservedObject var resources: ResourceMonitor
    let app: AppDelegate

    var body: some View {
        TabView {
            EngineTab(model: model).tabItem { Label("엔진", systemImage: "cpu") }
            SubtitleTab(model: model, app: app).tabItem { Label("자막", systemImage: "captions.bubble") }
            ResourceTab(model: model, resources: resources).tabItem { Label("리소스", systemImage: "gauge.with.dots.needle.33percent") }
            AboutTab().tabItem { Label("정보", systemImage: "info.circle") }
        }
        .frame(width: 760, height: 620)
    }
}

// MARK: - 엔진

struct EngineTab: View {
    @ObservedObject var model: SubtitleModel

    var body: some View {
        Form {
            Section("음성 인식") {
                Picker("엔진", selection: Binding(get: { model.engineChoice }, set: { model.selectEngine($0) })) {
                    ForEach(EngineChoice.allCases) { Text($0.title).tag($0) }
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
            Section("번역 (Apple 기기 내 번역, 영어 → 한국어)") {
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
                Toggle("영어 원문 함께 표시 (⌘E)", isOn: $model.showEnglish)
                Toggle("직전 문장 흐리게 표시", isOn: $model.showPrevious)
            }
            Section("창") {
                HStack {
                    Button("자막 창 위치·크기 초기화") { app.resetOverlayPosition(nil) }
                    Button("자막 지우기 (⌘K)") { model.clear() }
                }
                Text("자막 창은 배경을 잡고 드래그해 옮기고, 가장자리를 끌어 크기를 바꿀 수 있습니다. 위치는 자동 저장됩니다. 메뉴바 아이콘에서 숨기거나 다시 표시할 수 있습니다 (⌘H).")
                    .font(.caption).foregroundStyle(.secondary)
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
                LabeledContent("음성 인식 모델 캐시", value: String(format: "%.0f MB  (~/Library/Application Support/FluidAudio/Models)", resources.modelCacheMB))
                Text("Neural Engine 사용량은 macOS가 앱에 제공하지 않습니다. 엔진별 실측 전력은 엔진 탭의 표를 참고하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("시스템") {
                LabeledContent("전체 CPU 사용률", value: String(format: "%.0f %%", resources.systemCPU))
                LabeledContent("열 상태", value: resources.thermal)
                LabeledContent("저전력 모드", value: resources.lowPower ? "켜짐" : "꺼짐")
                LabeledContent("배터리", value: resources.battery)
            }
            Section("이번 세션") {
                LabeledContent("경과 시간", value: model.stats.elapsedText)
                LabeledContent("확정 문장", value: "\(model.stats.sentences)개")
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
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LiveSubtitle").font(.title2.bold())
                        Text("실시간 영어 → 한국어 자막 · 버전 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                        Text("음성과 텍스트는 이 맥 밖으로 나가지 않습니다 (인식·번역 모두 기기 내 처리).").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("사용한 구성요소") {
                LabeledContent("음성 인식", value: "NVIDIA Parakeet TDT 0.6B v2 / Ultra (CC-BY-4.0) · FluidAudio (Apache 2.0) · Apple SpeechAnalyzer")
                LabeledContent("번역", value: "Apple Translation 프레임워크 (기기 내)")
                LabeledContent("평가", value: "LibriSpeech test-other, powermetrics · 자세한 내용은 EVAL.md")
            }
            Section("단축키") {
                Text("⌘,  설정      ⌘H  자막 창 보이기/숨기기      ⌘P  일시정지/재개      ⌘K  자막 지우기\n⌘=  글자 크게      ⌘-  글자 작게      ⌘E  영어 원문 표시      ⌘Q  종료")
                    .font(.system(size: 12, design: .monospaced))
            }
        }
        .formStyle(.grouped)
    }
}
