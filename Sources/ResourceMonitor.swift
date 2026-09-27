import Foundation
import IOKit.ps
import Darwin

/// 이 프로세스와 시스템의 자원 사용량을 1초마다 표본화
@MainActor
final class ResourceMonitor: ObservableObject {
    @Published var processCPU: Double = 0      // 이 앱의 CPU 사용률 (%, 코어 1개 = 100)
    @Published var systemCPU: Double = 0       // 전체 시스템 CPU 사용률 (%)
    @Published var memoryMB: Double = 0        // 이 앱의 물리 메모리 사용량 (MB)
    @Published var thermal = "정상"
    @Published var lowPower = false
    @Published var battery = "-"
    @Published var modelCacheMB: Double = 0

    private var timer: Timer?
    private var lastProcTime: Double = -1
    private var lastWall = Date()
    private var lastTicks: (u: UInt64, s: UInt64, i: UInt64, n: UInt64)?
    private var cacheTick = 0

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
        case .nominal: thermal = "정상"
        case .fair: thermal = "약간 높음"
        case .serious: thermal = "높음 (성능 제한 가능)"
        case .critical: thermal = "매우 높음"
        @unknown default: thermal = "?"
        }
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        battery = Self.batteryDescription()

        // 모델 캐시 용량은 30초마다
        cacheTick += 1
        if cacheTick % 30 == 1 {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/FluidAudio/Models")
            DispatchQueue.global(qos: .utility).async {
                let mb = Self.directorySizeMB(dir)
                DispatchQueue.main.async { self.modelCacheMB = mb }
            }
        }
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
}
