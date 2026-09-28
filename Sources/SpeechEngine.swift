import Foundation
import Speech
import AVFoundation

/// 마이크 → 영어 음성 인식(SFSpeechRecognizer). 문장 단위로 잘라서 partial / final 콜백을 보낸다.
final class SpeechEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onStatus: ((String, Bool) -> Void)?   // (메시지, 듣는 중 여부)
    var onAudio: ((AVAudioPCMBuffer) -> Void)?     // 마이크 원본 버퍼 (세션 녹음용, 탭 스레드에서 호출)

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let q = DispatchQueue(label: "speech.engine")

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timer: Timer?

    private var lastPartial = ""
    private var lastPartialAt = Date()
    private var segmentStartAt = Date()
    private var running = false
    private var onDevice = false
    private var quickFailures = 0          // 결과 없이 바로 실패한 횟수 (연속)
    private var taskStartedAt = Date()

    // 문장 분할 파라미터
    private let pauseToCommit: TimeInterval = 0.9      // 이 정도 쉬면 문장 확정
    private let minWordsToCommit = 8                    // 최소 단어 수 (짧으면 좀 더 기다림)
    private let maxSegmentSeconds: TimeInterval = 25    // 너무 길어지면 강제 확정
    private let hardLimitSeconds: TimeInterval = 50     // 서버 인식은 60초 제한

    func start() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self else { return }
            guard status == .authorized else {
                self.status("음성 인식 권한이 필요합니다 (시스템 설정 > 개인정보 보호 > 음성 인식)", false)
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                guard granted else {
                    self.status("마이크 권한이 필요합니다 (시스템 설정 > 개인정보 보호 > 마이크)", false)
                    return
                }
                DispatchQueue.main.async { self.startEngine() }
            }
        }
    }

    func stop() {
        q.sync {
            running = false
            request = nil
            task?.cancel()
            task = nil
            lastPartial = ""
        }
        timer?.invalidate()
        timer = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        status("일시정지", false)
    }

    private func status(_ message: String, _ listening: Bool) {
        DispatchQueue.main.async { self.onStatus?(message, listening) }
    }

    private func startEngine() {
        guard let recognizer, recognizer.isAvailable else {
            status("영어 음성 인식을 사용할 수 없습니다", false)
            return
        }
        onDevice = recognizer.supportsOnDeviceRecognition
        FileLog.write("engine start: onDevice=\(onDevice) available=\(recognizer.isAvailable)")

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.onAudio?(buffer)
            self.q.async { self.request?.append(buffer) }
        }
        engine.prepare()
        FileLog.write("input format: \(format)")
        do {
            try engine.start()
        } catch {
            FileLog.write("engine.start failed: \(error)")
            status("마이크 시작 실패: \(error.localizedDescription)", false)
            return
        }

        q.async {
            self.running = true
            self.startTask()
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.q.async { self?.tick() }
        }
        status(onDevice ? "듣는 중 (기기 내 인식)" : "듣는 중 (서버 인식, 인터넷 필요)", true)
    }

    /// q에서 호출
    private func startTask() {
        guard running, let recognizer else { return }
        task?.cancel()
        task = nil

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.requiresOnDeviceRecognition = onDevice
        if #available(macOS 13.0, *) { req.addsPunctuation = true }
        request = req
        lastPartial = ""
        lastPartialAt = Date()
        segmentStartAt = Date()
        taskStartedAt = Date()

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            self.q.async {
                // 이미 교체된 예전 요청의 콜백은 무시
                guard self.request === req else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.commit(text)
                        self.restart(after: 0.05)
                        return
                    }
                    if text != self.lastPartial {
                        self.quickFailures = 0
                        self.lastPartial = text
                        self.lastPartialAt = Date()
                        let t = text
                        DispatchQueue.main.async { self.onPartial?(t) }
                    }
                }
                if let error {
                    let ns = error as NSError
                    let age = Date().timeIntervalSince(self.taskStartedAt)
                    FileLog.write("task error after \(String(format: "%.2f", age))s: \(ns.domain) code=\(ns.code) \(ns.localizedDescription) \(ns.userInfo)")
                    let hadText = !self.lastPartial.isEmpty
                    // 무음/타임아웃 등으로 끝남 → 지금까지 인식된 내용은 확정하고 새로 시작
                    self.commit(self.lastPartial)

                    var delay: TimeInterval = 0.2
                    if !hadText && age < 2 {
                        self.quickFailures += 1
                        delay = min(5, 0.5 * Double(self.quickFailures))   // 계속 실패하면 점점 천천히
                        if self.quickFailures == 3 && self.onDevice {
                            // 기기 내 인식이 계속 바로 실패하면 서버 인식으로 전환
                            self.onDevice = false
                            FileLog.write("switching to server recognition")
                            self.status("듣는 중 (서버 인식으로 전환, 인터넷 필요)", true)
                        }
                        if self.quickFailures >= 6 {
                            self.status("음성 인식 오류: \(ns.localizedDescription) (code \(ns.code))", false)
                        }
                    }
                    self.restart(after: delay)
                }
            }
        }
    }

    /// q에서 호출
    private func commit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lastPartial = ""
        guard !trimmed.isEmpty else { return }
        DispatchQueue.main.async { self.onFinal?(trimmed) }
    }

    /// q에서 호출
    private func restart(after delay: TimeInterval) {
        request = nil
        task = nil
        q.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.startTask()
        }
    }

    /// q에서 주기적으로 호출: 쉼(pause)이 생기면 문장을 확정해서 자막이 계속 넘어가게 함
    private func tick() {
        guard running, let req = request else { return }
        let now = Date()
        let sinceLastPartial = now.timeIntervalSince(lastPartialAt)
        let segmentAge = now.timeIntervalSince(segmentStartAt)
        let words = lastPartial.split(separator: " ").count

        var shouldEnd = false
        if !lastPartial.isEmpty {
            if sinceLastPartial > pauseToCommit && words >= minWordsToCommit { shouldEnd = true }
            if sinceLastPartial > pauseToCommit * 2 { shouldEnd = true }
            if segmentAge > maxSegmentSeconds && sinceLastPartial > 0.4 { shouldEnd = true }
        }
        if segmentAge > hardLimitSeconds { shouldEnd = true }

        if shouldEnd {
            // endAudio → 곧 isFinal 결과(또는 에러)가 와서 commit + restart 됨
            req.endAudio()
            // 응답이 안 오는 경우 대비: 1.5초 뒤에도 같은 요청이면 강제 재시작
            q.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.request === req else { return }
                self.commit(self.lastPartial)
                self.restart(after: 0.05)
            }
        }
    }
}
