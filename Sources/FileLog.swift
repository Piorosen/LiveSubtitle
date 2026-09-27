import Foundation

/// ~/Library/Logs/LiveSubtitle.log 에 한 줄씩 기록 (문제 확인용)
enum FileLog {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("LiveSubtitle.log")
    }()
    private static let q = DispatchQueue(label: "filelog")
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func write(_ s: String) {
        let line = "\(fmt.string(from: Date())) \(s)\n"
        q.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.data(using: .utf8)!.write(to: url)
            }
        }
    }
}
