import Foundation
import IOKit
import IOKit.ps
import Darwin

/// 1초 간격 자원 사용량 표본 (메트릭 그래프·CSV의 한 행)
struct MetricSample: Identifiable {
    let t: Date
    let appCPU: Double       // 이 앱 CPU (%, 코어 1개 = 100)
    let sysCPU: Double       // 전체 시스템 CPU (%)
    let memMB: Double        // 이 앱 물리 메모리 (MB)
    let threads: Int         // 이 앱 스레드 수
    let powerW: Double?      // 시스템 전체 소비 전력 (W) — 배터리로 동작 중일 때만 측정 가능
    let thermalLevel: Int    // 0 정상 · 1 약간 높음 · 2 높음 · 3 매우 높음
    let sentences: Int       // 세션 누적 확정 문장 수
    let words: Int           // 세션 누적 영어 단어 수
    let asrUpdates: Int      // 세션 누적 음성 인식 결과(partial+final) 수
    var id: Date { t }
}

/// 이 프로세스와 시스템의 자원 사용량을 1초마다 표본화하고 최근 30분을 보관
@MainActor
final class ResourceMonitor: ObservableObject {
    @Published var processCPU: Double = 0      // 이 앱의 CPU 사용률 (%, 코어 1개 = 100)
    @Published var systemCPU: Double = 0       // 전체 시스템 CPU 사용률 (%)
    @Published var memoryMB: Double = 0        // 이 앱의 물리 메모리 사용량 (MB)
    @Published var threads = 0
    @Published var powerW: Double?             // 배터리 사용 중일 때 시스템 소비 전력 (W)
    @Published var thermal = "정상"
    @Published var thermalLevel = 0
    @Published var lowPower = false
    @Published var battery = "-"
    @Published var modelCacheMB: Double = 0
    @Published private(set) var history: [MetricSample] = []

    static let historyLimit = 30 * 60          // 30분

    /// 표본에 넣을 세션 누적 카운터 (SubtitleModel이 제공)
    var counters: (() -> (sentences: Int, words: Int, asrUpdates: Int))?
    /// 표본마다 호출 (세션 CSV 저장용)
    var onSample: ((MetricSample) -> Void)?

    private var timer: Timer?
    private var lastProcTime: Double = -1
    private var lastWall = Date()
    private var lastTicks: (u: UInt64, s: UInt64, i: UInt64, n: UInt64)?
    private var cacheTick = 0
    private var batteryService: io_service_t = 0

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func sample() {
        // 프로세스 CPU (user+sys 시간 변화량 / 벽시계)
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        let t = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
              + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
        let now = Date()
        let dt = now.timeIntervalSince(lastWall)
        if lastProcTime >= 0, dt > 0.2 { processCPU = max(0, (t - lastProcTime) / dt * 100) }
        lastProcTime = t
        lastWall = now

        // 메모리 (phys_footprint = 활성 상태 보기와 같은 기준)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS { memoryMB = Double(info.phys_footprint) / 1_048_576 }

        // 스레드 수
        var list: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        if task_threads(mach_task_self_, &list, &threadCount) == KERN_SUCCESS, let list {
            threads = Int(threadCount)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.size))
        }

        // 시스템 CPU
        var load = host_cpu_load_info()
        var cnt = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr2 = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &cnt)
            }
        }
        if kr2 == KERN_SUCCESS {
            let cur = (u: UInt64(load.cpu_ticks.0), s: UInt64(load.cpu_ticks.1), i: UInt64(load.cpu_ticks.2), n: UInt64(load.cpu_ticks.3))
            if let p = lastTicks {
                let busy = Double((cur.u - p.u) + (cur.s - p.s) + (cur.n - p.n))
                let total = busy + Double(cur.i - p.i)
                if total > 0 { systemCPU = busy / total * 100 }
            }
            lastTicks = cur
        }

        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "정상"; thermalLevel = 0
        case .fair: thermal = "약간 높음"; thermalLevel = 1
        case .serious: thermal = "높음 (성능 제한 가능)"; thermalLevel = 2
        case .critical: thermal = "매우 높음"; thermalLevel = 3
        @unknown default: thermal = "?"; thermalLevel = 0
        }
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        battery = Self.batteryDescription()
        powerW = readSystemPower()

        // 모델 캐시 용량은 30초마다
        cacheTick += 1
        if cacheTick % 30 == 1 {
            let dir = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                       ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")).appendingPathComponent("FluidAudio/Models")
            DispatchQueue.global(qos: .utility).async {
                let mb = Self.directorySizeMB(dir)
                DispatchQueue.main.async { self.modelCacheMB = mb }
            }
        }

        let c = counters?() ?? (sentences: 0, words: 0, asrUpdates: 0)
        let s = MetricSample(t: now, appCPU: processCPU, sysCPU: systemCPU, memMB: memoryMB, threads: threads,
                             powerW: powerW, thermalLevel: thermalLevel,
                             sentences: c.sentences, words: c.words, asrUpdates: c.asrUpdates)
        history.append(s)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        onSample?(s)
    }

    /// AppleSmartBattery 레지스트리의 순간 전류×전압. 방전 중(외부 전원 없음)일 때만 시스템 전체 소비 전력이 된다.
    /// 앱 하나의 전력이나 Neural Engine 전력은 macOS가 일반 앱에 제공하지 않음 (powermetrics는 root 필요).
    private func readSystemPower() -> Double? {
        if batteryService == 0 {
            batteryService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        }
        guard batteryService != 0 else { return nil }
        func prop(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(batteryService, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        guard let external = prop("ExternalConnected") as? Bool, !external,
              let mA = (prop("InstantAmperage") as? NSNumber)?.int64Value,
              let mV = (prop("Voltage") as? NSNumber)?.int64Value, mA < 0, mV > 0 else { return nil }
        return Double(-mA) * Double(mV) / 1_000_000
    }

    private static func batteryDescription() -> String {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return "-" }
        for src in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, src)?.takeUnretainedValue() as? [String: Any] else { continue }
            let cap = desc[kIOPSCurrentCapacityKey as String] as? Int ?? -1
            let charging = desc[kIOPSIsChargingKey as String] as? Bool ?? false
            let state = desc[kIOPSPowerSourceStateKey as String] as? String ?? ""
            let onAC = state == (kIOPSACPowerValue as String)
            var s = cap >= 0 ? "\(cap)%" : "?"
            if charging { s += " 충전 중" } else if onAC { s += " 전원 연결" } else { s += " 배터리 사용 중" }
            if let mins = desc[kIOPSTimeToEmptyKey as String] as? Int, mins > 0, !onAC { s += " · 약 \(mins / 60)시간 \(mins % 60)분 남음" }
            return s
        }
        return "배터리 없음"
    }

    private static func directorySizeMB(_ url: URL) -> Double {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let f as URL in e {
            total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return Double(total) / 1_048_576
    }

    /// 보관 중인 표본 전체를 CSV로
    func historyCSV() -> String {
        var s = "time,app_cpu_pct,sys_cpu_pct,mem_mb,threads,power_w,thermal,sentences,words,asr_updates\n"
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        for m in history {
            s += String(format: "%@,%.1f,%.1f,%.1f,%d,%@,%d,%d,%d,%d\n", f.string(from: m.t), m.appCPU, m.sysCPU, m.memMB, m.threads,
                        m.powerW.map { String(format: "%.2f", $0) } ?? "", m.thermalLevel, m.sentences, m.words, m.asrUpdates)
        }
        return s
    }
}
