// Apple SpeechAnalyzer(macOS 26) 파일 전사 CLI: applestt <wav 파일들...>  → 각 파일 전사를 "<파일명>\t<텍스트>" 로 출력
import Foundation
import Speech
import AVFoundation

@available(macOS 26, *)
func transcribe(_ path: String) async throws -> (String, Double) {
    let locale = Locale(identifier: "en-US")
    guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw NSError(domain: "x", code: 1) }
    let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    if await AssetInventory.status(forModules: [transcriber]) != .installed,
       let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try await req.downloadAndInstall()
    }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw NSError(domain: "x", code: 2) }

    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let inFmt = file.processingFormat
    guard let conv = AVAudioConverter(from: inFmt, to: fmt) else { throw NSError(domain: "x", code: 3) }
    let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()

    var collected: [String] = []
    let collector = Task {
        for try await r in transcriber.results where r.isFinal {
            collected.append(String(r.text.characters))
        }
    }
    let t0 = Date()
    try await analyzer.start(inputSequence: stream)

    let frames: AVAudioFrameCount = 16384
    while file.framePosition < file.length {
        guard let buf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: frames) else { break }
        try file.read(into: buf, frameCount: frames)
        if buf.frameLength == 0 { break }
        let ratio = fmt.sampleRate / inFmt.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * ratio) + 32) else { break }
        var used = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, st in
            if used { st.pointee = .noDataNow; return nil }
            used = true; st.pointee = .haveData; return buf
        }
        if out.frameLength > 0 { builder.yield(AnalyzerInput(buffer: out)) }
    }
    builder.finish()
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    try await collector.value
    let elapsed = Date().timeIntervalSince(t0)
    return (collected.joined(separator: " "), elapsed)
}

if #available(macOS 26, *) {
    let sem = DispatchSemaphore(value: 0)
    Task {
        for path in CommandLine.arguments.dropFirst() {
            do {
                let (text, secs) = try await transcribe(path)
                let name = (path as NSString).lastPathComponent
                print("\(name)\t\(secs)\t\(text)")
            } catch {
                FileHandle.standardError.write("ERROR \(path): \(error)\n".data(using: .utf8)!)
            }
        }
        sem.signal()
    }
    sem.wait()
}
