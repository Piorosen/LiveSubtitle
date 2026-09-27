import AppKit
import SwiftUI
import Carbon.HIToolbox

/// 테두리 없는 창도 키 입력(⌘, 등)을 받을 수 있게 하는 서브클래스
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = SubtitleModel()
    let resources = ResourceMonitor()

    var overlay: OverlayWindow!
    var settingsWindow: NSWindow?
    var statusItem: NSStatusItem!
    /// 숨김 상태는 세션 동안만 유지. 앱을 켜면 항상 자막 창이 보임 (숨긴 채로 시작해 헷갈리는 일 방지)
    var overlayVisible = true {
        didSet { updateStatusIcon() }
    }

    // MARK: 시작

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)      // Dock에 표시하지 않음 (Info.plist LSUIElement와 함께)
        makeOverlay()
        makeStatusItem()
        NSApp.mainMenu = makeMainMenu()             // 창이 활성일 때 단축키 동작용
        resources.start()
        model.start()
        registerGlobalHotKey()
        installDebugHooks()
    }

    // MARK: 전역 단축키 ⌥⌘L — 어떤 앱이 활성이어도 자막 창 보이기/숨기기 (메뉴바 아이콘이 노치에 가려져도 복구 가능)

    private var hotKeyRef: EventHotKeyRef?
    private func registerGlobalHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.toggleOverlay(nil) }
            return noErr
        }, 1, &spec, nil, nil)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C53_5542), id: 1)   // "LSUB"
        RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(cmdKey | optionKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: 자막 오버레이 창

    private func makeOverlay() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(1100, screen.width * 0.85)
        let frame = NSRect(x: screen.midX - width / 2, y: screen.minY + 40, width: width, height: 210)
        overlay = OverlayWindow(contentRect: frame, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.level = .floating
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        overlay.isMovableByWindowBackground = true
        overlay.minSize = NSSize(width: 360, height: 100)
        overlay.title = "LiveSubtitle"
        overlay.contentView = NSHostingView(rootView: SubtitleView(model: model))
        overlay.setFrameAutosaveName("SubtitleOverlay")   // 위치·크기 저장
        overlay.orderFrontRegardless()
    }

    @objc func toggleOverlay(_ sender: Any?) {
        overlayVisible.toggle()
        if overlayVisible { overlay.orderFrontRegardless() } else { overlay.orderOut(nil) }
    }

    @objc func resetOverlayPosition(_ sender: Any?) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(1100, screen.width * 0.85)
        overlay.setFrame(NSRect(x: screen.midX - width / 2, y: screen.minY + 40, width: width, height: 210), display: true, animate: true)
        if !overlayVisible { toggleOverlay(nil) }
    }

    // MARK: 메뉴바

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.behavior = []          // ⌘드래그로 제거되지 않음
        statusItem.isVisible = true
        statusItem.autosaveName = "LiveSubtitleStatus"
        updateStatusIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// 자막 창이 보이면 채워진 말풍선, 숨겨져 있으면 빈 말풍선
    private func updateStatusIcon() {
        guard let b = statusItem?.button else { return }
        b.image = NSImage(systemSymbolName: overlayVisible ? "captions.bubble.fill" : "captions.bubble", accessibilityDescription: "LiveSubtitle")
        b.image?.isTemplate = true
        b.imagePosition = .imageLeading
        b.title = overlayVisible ? " 자막" : " 자막(숨김)"
        b.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        b.toolTip = overlayVisible ? "LiveSubtitle — ⌥⌘L 로 자막 창 숨기기/보이기" : "LiveSubtitle — 자막 창 숨김. 클릭 또는 ⌥⌘L 로 다시 표시"
    }

    /// 메뉴를 열 때마다 현재 상태로 다시 구성
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // 맨 위: 자막 창 보이기/숨기기 (숨겨져 있으면 굵게 강조)
        let show = NSMenuItem(title: overlayVisible ? "자막 창 숨기기  (⌥⌘L)" : "자막 창 보이기  (⌥⌘L)", action: #selector(toggleOverlay(_:)), keyEquivalent: "")
        show.target = self
        if !overlayVisible {
            show.attributedTitle = NSAttributedString(string: "자막 창 보이기  (⌥⌘L)", attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        }
        menu.addItem(show)
        menu.addItem(.separator())

        let dot = model.paused ? "⏸" : (model.isListening ? "●" : "○")
        let engineLine = "\(dot) \(model.paused ? "일시정지" : model.status)"
        let s1 = NSMenuItem(title: engineLine, action: nil, keyEquivalent: ""); s1.isEnabled = false; menu.addItem(s1)
        let s2 = NSMenuItem(title: String(format: "CPU %.0f%% · 메모리 %.0f MB · 번역 %@", resources.processCPU, resources.memoryMB, model.translationReady ? "준비됨" : "준비 안 됨"),
                            action: nil, keyEquivalent: ""); s2.isEnabled = false; menu.addItem(s2)
        menu.addItem(.separator())

        let pause = NSMenuItem(title: model.paused ? "재개" : "일시정지", action: #selector(togglePause(_:)), keyEquivalent: "p")
        pause.target = self; menu.addItem(pause)
        let clear = NSMenuItem(title: "자막 지우기", action: #selector(clearLines(_:)), keyEquivalent: "k")
        clear.target = self; menu.addItem(clear)
        menu.addItem(.separator())

        let engineMenu = NSMenu()
        for c in EngineChoice.allCases {
            let it = NSMenuItem(title: c.title, action: #selector(pickEngine(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = c.rawValue
            it.state = (c == model.engineChoice) ? .on : .off
            engineMenu.addItem(it)
        }
        engineMenu.addItem(.separator())
        for p in LatencyPreset.allCases {
            let it = NSMenuItem(title: p.title, action: #selector(pickPreset(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = p.rawValue
            it.state = (p == model.latencyPreset) ? .on : .off
            it.isEnabled = model.engineChoice != .apple
            engineMenu.addItem(it)
        }
        let engineItem = NSMenuItem(title: "음성 인식 엔진", action: nil, keyEquivalent: "")
        engineItem.submenu = engineMenu
        menu.addItem(engineItem)

        let settings = NSMenuItem(title: "설정…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "LiveSubtitle 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc func pickEngine(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let c = EngineChoice(rawValue: raw) { model.selectEngine(c) }
    }
    @objc func pickPreset(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let p = LatencyPreset(rawValue: raw) { model.selectPreset(p) }
    }

    // MARK: 설정 창

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "LiveSubtitle 설정"
            w.level = .floating
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model, resources: resources, app: self))
            w.center()
            w.setFrameAutosaveName("Settings")
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 공통 액션

    @objc func togglePause(_ sender: Any?) { model.togglePause() }
    @objc func clearLines(_ sender: Any?) { model.clear() }
    @objc func fontBigger(_ sender: Any?) { model.fontSize = min(80, model.fontSize + 2) }
    @objc func fontSmaller(_ sender: Any?) { model.fontSize = max(16, model.fontSize - 2) }
    @objc func toggleEnglish(_ sender: Any?) { model.showEnglish.toggle() }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "설정…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "LiveSubtitle 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let view = NSMenu(title: "보기")
        view.addItem(withTitle: "자막 창 보이기/숨기기", action: #selector(toggleOverlay(_:)), keyEquivalent: "h").target = self
        view.addItem(withTitle: "일시정지 / 재개", action: #selector(togglePause(_:)), keyEquivalent: "p").target = self
        view.addItem(withTitle: "자막 지우기", action: #selector(clearLines(_:)), keyEquivalent: "k").target = self
        view.addItem(withTitle: "글자 크게", action: #selector(fontBigger(_:)), keyEquivalent: "=").target = self
        view.addItem(withTitle: "글자 작게", action: #selector(fontSmaller(_:)), keyEquivalent: "-").target = self
        view.addItem(withTitle: "영어 원문 표시 전환", action: #selector(toggleEnglish(_:)), keyEquivalent: "e").target = self
        viewItem.submenu = view
        return main
    }

    // MARK: 디버그 훅 (LIVESUB_SNAPSHOT=<png>: 2초마다 창 내용을 저장, LIVESUB_SHOW_SETTINGS=1: 설정 창 자동 열기)

    private func installDebugHooks() {
        guard let path = ProcessInfo.processInfo.environment["LIVESUB_SNAPSHOT"] else { return }
        if ProcessInfo.processInfo.environment["LIVESUB_SHOW_SETTINGS"] != nil { showSettings(nil) }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveSnapshot(of: self.overlay, to: path)
                if let sw = self.settingsWindow, sw.isVisible, let v = sw.contentView {
                    self.saveSnapshot(of: sw, to: path.replacingOccurrences(of: ".png", with: "-settings.png"))
                    try? v.dataWithPDF(inside: v.bounds).write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-settings.pdf")))
                }
            }
        }
    }

    private func saveSnapshot(of window: NSWindow, to path: String) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
