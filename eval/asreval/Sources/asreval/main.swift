// FluidAudio(Parakeet CoreML) 배치 평가: asreval <v2|v3|ultra> <wav...>  → "<파일>\t<초>\t<텍스트>"
import Foundation
import FluidAudio

let args = CommandLine.arguments.dropFirst()
guard let ver = args.first else { print("usage: asreval <v2|v3|ultra> files..."); exit(1) }
let files = Array(args.dropFirst())

let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let version: AsrModelVersion = (ver == "v2") ? .v2 : (ver == "ultra") ? .ultra : .v3
        let t0 = Date()
        let models = try await AsrModels.downloadAndLoad(version: version)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        FileHandle.standardError.write("model \(ver) loaded in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s\n".data(using: .utf8)!)
        for f in files {
            let t = Date()
            var state = TdtDecoderState.make()
            let r = try await asr.transcribe(URL(fileURLWithPath: f), decoderState: &state)
            let secs = Date().timeIntervalSince(t)
            print("\((f as NSString).lastPathComponent)\t\(secs)\t\(r.text)")
        }
    } catch {
        FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
    }
    sem.signal()
}
sem.wait()
