import SwiftUI
import Charts
import AppKit

/// 설정 > 메트릭: 자원 사용량·연산 지표를 시간축 그래프로. 표본은 ResourceMonitor(1초), 번역 지연은 SubtitleModel(문장마다).
struct MetricsTab: View {
    @ObservedObject var model: SubtitleModel
    @ObservedObject var resources: ResourceMonitor
    @State private var windowMinutes = 5

    private var now: Date { resources.history.last?.t ?? Date() }
    private var windowStart: Date { now.addingTimeInterval(-Double(windowMinutes * 60)) }
    private var domain: ClosedRange<Date> { windowStart...now }

    /// 창 안의 원본 표본 (1초 간격)
    private var raw: [MetricSample] {
        let start = windowStart
        if let i = resources.history.firstIndex(where: { $0.t >= start }) { return Array(resources.history[i...]) }
        return []
    }

    /// 그래프용 다운샘플 (최대 ~360점, 구간 평균)
    private var samples: [Row] {
        let r = raw
        guard !r.isEmpty else { return [] }
        // 분당 처리량: 60초 전 표본과의 누적 카운터 차이
        var rows: [Row] = []
        rows.reserveCapacity(r.count)
        var j = 0
        for (i, m) in r.enumerated() {
            while j < i, r[j].t < m.t.addingTimeInterval(-60) { j += 1 }
            let span = max(1, m.t.timeIntervalSince(r[j].t))
            let scale = i == j ? 0 : 60 / span
            rows.append(Row(t: m.t, appCPU: m.appCPU, sysCPU: m.sysCPU, memMB: m.memMB, powerW: m.powerW,
                            wordsPerMin: Double(m.words - r[j].words) * scale,
                            updatesPerMin: Double(m.asrUpdates - r[j].asrUpdates) * scale))
        }
        let k = Int(ceil(Double(rows.count) / 360))
        guard k > 1 else { return rows }
        return stride(from: 0, to: rows.count, by: k).map { s in
            let g = rows[s..<min(s + k, rows.count)]
            let n = Double(g.count)
            let pw = g.compactMap(\.powerW)
            return Row(t: g[g.startIndex].t,
                       appCPU: g.reduce(0) { $0 + $1.appCPU } / n, sysCPU: g.reduce(0) { $0 + $1.sysCPU } / n,
                       memMB: g.reduce(0) { $0 + $1.memMB } / n,
                       powerW: pw.isEmpty ? nil : pw.reduce(0, +) / Double(pw.count),
                       wordsPerMin: g.reduce(0) { $0 + $1.wordsPerMin } / n, updatesPerMin: g.reduce(0) { $0 + $1.updatesPerMin } / n)
        }
    }

    private var latencies: [SubtitleModel.LatencyPoint] {
        let start = windowStart
        return model.stats.latencies.filter { $0.t >= start }
    }

    struct Row: Identifiable {
        let t: Date
        let appCPU, sysCPU, memMB: Double
        let powerW: Double?
        let wordsPerMin, updatesPerMin: Double
        var id: Date { t }
    }

    var body: some View {
        let s = samples           // 1초에 한 번, 여기서만 계산
        let lat = latencies
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Picker("범위", selection: $windowMinutes) {
                        Text("1분").tag(1); Text("5분").tag(5); Text("10분").tag(10); Text("30분").tag(30)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                    Text("1초 간격 표본 · 최근 30분 보관").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("CSV 내보내기…") { exportCSV() }
                }
                tiles(s)
                card("CPU 사용률", unit: "%", count: s.count, note: "앱은 코어 1개 = 100%, 시스템은 전체 코어 기준") { cpuChart(s) }
                card("메모리 (이 앱, 물리 메모리)", unit: "MB", count: s.count, note: nil) { memoryChart(s) }
                card("시스템 소비 전력", unit: "W", count: s.count, note: resources.powerW == nil
                     ? "배터리로 동작할 때만 측정됩니다 (전원 연결 중에는 값 없음). 앱 하나의 전력·Neural Engine 전력은 macOS가 제공하지 않습니다."
                     : "배터리 순간 전류×전압. 맥 전체 값이며 이 앱만의 소비는 아닙니다. 엔진별 실측 추가 전력은 엔진 탭 표 참고.") { powerChart(s) }
                card("번역 지연 (확정 문장마다)", unit: "ms", count: s.count, note: "영어 문장 확정 → 한국어 번역 완료까지 (Apple 기기 내 번역)") { latencyChart(lat) }
                HStack(alignment: .top, spacing: 12) {
                    card("인식 처리량", unit: "단어/분", count: s.count, note: "최근 60초 동안 확정된 영어 단어 수") { wordsChart(s) }
                    card("인식 결과 수신", unit: "회/분", count: s.count, note: "엔진이 보낸 partial·final 결과 (창·프리셋에 따라 다름)") { updatesChart(s) }
                }
            }
            .padding(16)
        }
    }

    // MARK: 현재 값 타일

    private func tiles(_ samples: [Row]) -> some View {
        HStack(spacing: 10) {
            tile("앱 CPU", String(format: "%.0f", resources.processCPU), "%")
            tile("메모리", String(format: "%.0f", resources.memoryMB), "MB")
            tile("스레드", "\(resources.threads)", "")
            tile("전력", resources.powerW.map { String(format: "%.1f", $0) } ?? "—", resources.powerW == nil ? "전원 연결" : "W")
            tile("단어/분", String(format: "%.0f", samples.last?.wordsPerMin ?? 0), "")
            tile("번역 지연", model.stats.avgTranslationMs > 0 ? String(format: "%.0f", model.stats.avgTranslationMs) : "—", "ms 평균")
        }
    }

    private func tile(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: 카드

    private func card<C: View>(_ title: String, unit: String, count: Int, note: String?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            if count < 2 {
                Text("표본 수집 중…").font(.caption).foregroundStyle(.secondary).frame(height: 140)
            } else {
                content().frame(height: 140)
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
    }

    // MARK: 차트

    private var xAxis: some AxisContent {
        let stride: Int = windowMinutes <= 1 ? 15 : (windowMinutes <= 5 ? 60 : (windowMinutes <= 10 ? 120 : 300))
        return AxisMarks(values: .stride(by: .second, count: stride)) { _ in
            AxisGridLine().foregroundStyle(.quaternary)
            AxisValueLabel(format: windowMinutes <= 1 ? .dateTime.hour().minute().second() : .dateTime.hour().minute())
        }
    }

    private func cpuChart(_ samples: [Row]) -> some View {
        Chart(samples) { r in
            LineMark(x: .value("시간", r.t), y: .value("CPU", r.appCPU), series: .value("계열", "앱"))
                .foregroundStyle(by: .value("계열", "앱")).lineStyle(ChartPalette.line).interpolationMethod(.monotone)
            LineMark(x: .value("시간", r.t), y: .value("CPU", r.sysCPU), series: .value("계열", "시스템"))
                .foregroundStyle(by: .value("계열", "시스템")).lineStyle(ChartPalette.line).interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale(["앱": ChartPalette.blue, "시스템": ChartPalette.orange])
        .chartLegend(position: .top, alignment: .leading)
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...max(100, (samples.map { max($0.appCPU, $0.sysCPU) }.max() ?? 100) * 1.1))
        .chartXAxis { xAxis }
        .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
    }

    private func memoryChart(_ samples: [Row]) -> some View {
        Chart(samples) { r in
            AreaMark(x: .value("시간", r.t), y: .value("MB", r.memMB))
                .foregroundStyle(ChartPalette.aqua.opacity(0.18)).interpolationMethod(.monotone)
            LineMark(x: .value("시간", r.t), y: .value("MB", r.memMB))
                .foregroundStyle(ChartPalette.aqua).lineStyle(ChartPalette.line).interpolationMethod(.monotone)
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...max(100, (samples.map(\.memMB).max() ?? 100) * 1.15))
        .chartXAxis { xAxis }
        .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
    }

    private func powerChart(_ samples: [Row]) -> some View {
        let pts = samples.compactMap { r in r.powerW.map { (t: r.t, w: $0) } }
        return Chart {
            ForEach(pts, id: \.t) { p in
                LineMark(x: .value("시간", p.t), y: .value("W", p.w)).foregroundStyle(ChartPalette.yellow).lineStyle(ChartPalette.line).interpolationMethod(.monotone)
            }
            if pts.isEmpty {
                RuleMark(y: .value("W", 0)).foregroundStyle(.clear)
                    .annotation(position: .overlay) { Text("전원 연결 중 — 배터리로 전환하면 표시됩니다").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...max(5, (pts.map(\.w).max() ?? 5) * 1.2))
        .chartXAxis { xAxis }
        .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
    }

    private func latencyChart(_ pts: [SubtitleModel.LatencyPoint]) -> some View {
        return Chart {
            ForEach(pts) { p in
                BarMark(x: .value("시간", p.t), y: .value("ms", p.ms), width: .fixed(3))
                    .foregroundStyle(ChartPalette.violet).cornerRadius(1.5)
            }
            if model.stats.avgTranslationMs > 0 {
                RuleMark(y: .value("평균", model.stats.avgTranslationMs))
                    .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text(String(format: "평균 %.0f ms", model.stats.avgTranslationMs)).font(.caption2).foregroundStyle(.secondary)
                    }
            }
            if pts.isEmpty {
                RuleMark(y: .value("ms", 0)).foregroundStyle(.clear)
                    .annotation(position: .overlay) { Text("이 범위에 확정된 문장이 없습니다").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...max(200, (pts.map(\.ms).max() ?? 200) * 1.15))
        .chartXAxis { xAxis }
        .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
    }

    private func wordsChart(_ samples: [Row]) -> some View {
        Chart(samples) { r in
            AreaMark(x: .value("시간", r.t), y: .value("단어/분", r.wordsPerMin))
                .foregroundStyle(ChartPalette.blue.opacity(0.18)).interpolationMethod(.monotone)
            LineMark(x: .value("시간", r.t), y: .value("단어/분", r.wordsPerMin)).foregroundStyle(ChartPalette.blue).lineStyle(ChartPalette.line).interpolationMethod(.monotone)
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...max(60, (samples.map(\.wordsPerMin).max() ?? 60) * 1.15))
        .chartXAxis { xAxis }
        .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
    }

    private func updatesChart(_ samples: [Row]) -> some View {
        Chart(samples) { r in
            LineMark(x: .value("시간", r.t), y: .value("회/분", r.updatesPerMin)).foregroundStyle(ChartPalette.magenta).lineStyle(ChartPalette.line).interpolationMethod(.monotone)
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...max(30, (samples.map(\.updatesPerMin).max() ?? 30) * 1.15))
        .chartXAxis { xAxis }
        .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
    }

    // MARK: CSV

    private func exportCSV() {
        let panel = NSSavePanel()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH-mm"
        panel.nameFieldStringValue = "LiveSubtitle metrics \(f.string(from: Date())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            try? resources.historyCSV().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
