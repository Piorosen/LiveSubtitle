// 스트리밍(슬라이딩 창) 설정별 정확도 평가: streamtest <chunk> <left> <right> <files...>
// 파일을 100ms 버퍼로 잘라 SlidingWindowAsrManager에 흘려 넣고, 확정 업데이트 + finish() 텍스트를 출력
import Foundation
import AVFoundation
import FluidAudio

let a = Array(CommandLine.arguments.dropFirst())
guard a.count >= 4, let chunk = Double(a[0]), let left = Double(a[1]), let right = Double(a[2]) else {
    print("usage: streamtest <chunkSec> <leftSec> <rightSec> files..."); exit(1)
}
let files = Array(a[3...])
let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        for f in files {
            let cfg = SlidingWindowAsrConfig(chunkSeconds: chunk, hypothesisChunkSeconds: 1.0,
                                             leftContextSeconds: left, rightContextSeconds: right,
                                             minContextForConfirmation: chunk, confirmationThreshold: 0.8)
            let mgr = SlidingWindowAsrManager(config: cfg)
            try await mgr.loadModels(models)
            let updates = await mgr.transcriptionUpdates
            var nUpdates = 0, nConfirmed = 0
            let counter = Task { for await u in updates { nUpdates += 1; if u.isConfirmed { nConfirmed += 1 } } }
            try await mgr.startStreaming(source: .system)
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: f))
            let fmt = file.processingFormat
            let step = AVAudioFrameCount(fmt.sampleRate / 10)
            let t0 = Date()
            while file.framePosition < file.length {
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: step) else { break }
                try file.read(into: buf, frameCount: step)
                if buf.frameLength == 0 { break }
                await mgr.streamAudio(buf)
            }
            let text = try await mgr.finish()
            let secs = Date().timeIntervalSince(t0)
            counter.cancel()
            print("\((f as NSString).lastPathComponent)\t\(secs)\t\(text)")
            FileHandle.standardError.write("\(f): updates=\(nUpdates) confirmed=\(nConfirmed)\n".data(using: .utf8)!)
            await mgr.cleanup()
        }
    } catch { FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!) }
    sem.signal()
}
sem.wait()
