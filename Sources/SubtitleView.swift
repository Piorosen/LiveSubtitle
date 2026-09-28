import SwiftUI
import Translation

/// 자막 오버레이: 텍스트만. 마우스를 올리면 얇은 상태 줄이 나타남.
struct SubtitleView: View {
    @ObservedObject var model: SubtitleModel
    @ObservedObject var recorder: SessionRecorder      // 세션 pill (녹음 시간·문장 수) 갱신용
    @State private var hovering = false

    init(model: SubtitleModel) {
        self.model = model
        self.recorder = model.recorder
    }

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(model.opacity))

            VStack(spacing: 8) {
                Spacer(minLength: 0)
                if model.showPrevious, !model.previousKorean.isEmpty {
                    Text(model.previousKorean)
                        .font(.system(size: model.fontSize * 0.68, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(2)
                }
                Text(model.currentKorean.isEmpty ? (model.isListening ? "듣는 중…" : model.status) : model.currentKorean)
                    .font(.system(size: model.fontSize, weight: .semibold))
                    .foregroundStyle(model.currentKorean.isEmpty ? .white.opacity(0.35) : .white)
                    .shadow(color: .black.opacity(0.9), radius: 3, x: 0, y: 1)
                    .lineLimit(3)
                    .animation(.easeOut(duration: 0.12), value: model.currentKorean)
                if model.showEnglish, !model.currentEnglish.isEmpty {
                    Text(model.currentEnglish)
                        .font(.system(size: model.fontSize * 0.48))
                        .foregroundStyle(Color(red: 1, green: 0.85, blue: 0.4).opacity(0.9))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 30)
            .padding(.top, model.alwaysShowControls ? 40 : 18)
            .padding(.bottom, 18)

            if hovering || model.alwaysShowControls { statusBar.transition(.opacity) }
        }
        .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { hovering = h } }
        .translationTask(model.translationConfig) { session in
            await model.runTranslationLoop(session)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(model.paused ? Color.orange : (model.isListening ? Color.green : Color.red)).frame(width: 7, height: 7)
            Text(model.paused ? "일시정지" : model.status)
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            if !model.translationReady {
                Text("· 번역 준비 안 됨").font(.system(size: 11)).foregroundStyle(.orange)
            }
            Spacer()
            modePill
            pill("list.bullet.rectangle", "세션 보기 — 저장된 세션의 자막·그래프·재생 (⌘L)") { (NSApp.delegate as? AppDelegate)?.showSessions(nil) }
            pill(model.paused ? "play.fill" : "pause.fill", model.paused ? "재개" : "일시정지") { model.togglePause() }
            pill("gearshape", "설정 (⌘,)") { (NSApp.delegate as? AppDelegate)?.showSettings(nil) }
            pill("eye.slash", "자막 창 숨기기 — 다시 보려면 메뉴바 '자막' 아이콘 또는 ⌥⌘L") { (NSApp.delegate as? AppDelegate)?.toggleOverlay(nil) }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.black.opacity(0.7), in: Capsule())
        .padding(8)
    }

    /// 세션 모드 표시/전환: 기본 모드에서는 "세션 시작", 세션 모드에서는 빨간 녹음 시간 + 문장 수
    private var modePill: some View {
        let rec = recorder
        return Button { (NSApp.delegate as? AppDelegate)?.toggleMode(nil) } label: {
            HStack(spacing: 5) {
                if rec.mode == .session {
                    Circle().fill(model.paused ? Color.orange : Color.red).frame(width: 7, height: 7)
                    Text("\(SessionRecorder.clock(rec.audioSeconds)) · \(rec.lines.count)문장")
                        .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.white)
                } else {
                    Image(systemName: "record.circle").font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                    Text("세션 시작").font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(rec.mode == .session ? Color.red.opacity(0.35) : Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(rec.mode == .session
              ? "세션 모드: 녹음·전사·메트릭을 \(rec.usingICloud ? "iCloud Drive" : "이 맥")에 저장 중. 클릭하면 세션 종료 (⌘R)"
              : "세션 시작: 녹음 + 시각 있는 전사 + 메트릭을 폴더에 저장 (⌘R). 기본 모드에서는 아무것도 저장하지 않음")
    }

    private func pill(_ symbol: String, _ tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).frame(width: 18, height: 18)
        }
        .buttonStyle(.plain).help(tip)
    }
}
