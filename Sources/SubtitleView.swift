import SwiftUI
import Translation

/// 자막 오버레이: 텍스트만. 마우스를 올리면 얇은 상태 줄이 나타남.
struct SubtitleView: View {
    @ObservedObject var model: SubtitleModel
    @State private var hovering = false

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
            .padding(.vertical, 18)

            if hovering { statusBar.transition(.opacity) }
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
            pill(model.paused ? "play.fill" : "pause.fill", model.paused ? "재개" : "일시정지") { model.togglePause() }
            pill("gearshape", "설정 (⌘,)") { (NSApp.delegate as? AppDelegate)?.showSettings(nil) }
            pill("eye.slash", "자막 창 숨기기 (메뉴바에서 다시 표시)") { (NSApp.delegate as? AppDelegate)?.toggleOverlay(nil) }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.black.opacity(0.7), in: Capsule())
        .padding(8)
    }

    private func pill(_ symbol: String, _ tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).frame(width: 18, height: 18)
        }
        .buttonStyle(.plain).help(tip)
    }
}
