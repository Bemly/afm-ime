import AppKit
import SwiftUI
import IMECore

// 伴随面板(⌃V 剪贴板 / ⌃F 翻译): 液态玻璃,候选条在 → 浮其下方(放不下 → 上方),
// 候选条不在 → 光标所在屏幕右上角。两者互斥,打开一个自动关另一个。
// 焦点模型: IME 进程平时 .prohibited 收不到键盘事件,面板需要键(数字选词/翻译输入),
// 打开时临时切 .accessory 激活,关闭时恢复 .prohibited 并 deactivate 把焦点还给原应用;
// 插入文本也在面板 close 还焦点后延迟执行(目标客户重新活跃后 IMK insertText 才可靠)。

// MARK: - 管理与定位

enum CompanionPanels {
    static let clipboard = ClipboardPanelController()
    static let translate = TranslatePanelController()

    /// 自己的面板持有键盘(如翻译框输入中)→ handle() 全放行,⌃V/⌃F 等快捷键不拦截
    static var anyKeyWindow: Bool {
        guard let key = NSApp.keyWindow else { return false }
        return key === clipboard.panel || key === translate.panel
    }

    static func toggleClipboard() {
        if clipboard.isVisible { clipboard.close(); return }
        translate.close()
        clipboard.open(caret: InputController.latestCaret, candidateFrame: InputController.latestCandidateFrame)
    }

    static func toggleTranslate() {
        if translate.isVisible { translate.close(); return }
        clipboard.close()
        translate.open(caret: InputController.latestCaret, candidateFrame: InputController.latestCandidateFrame)
    }

    /// 候选窗显示/移动/隐藏时同步重浮(latestCandidateFrame 由 InputController 经 onFrameChange 回写)
    static func repositionAll() {
        let caret = InputController.latestCaret
        let cand = InputController.latestCandidateFrame
        clipboard.reposition(caret: caret, candidateFrame: cand)
        translate.reposition(caret: caret, candidateFrame: cand)
    }

    /// 通用定位: 候选条下方,放不下 → 上方;无候选条 → 光标所在屏幕右上角
    static func origin(size: NSSize, caret: NSRect, candidateFrame: NSRect) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(caret) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if !candidateFrame.isNull, candidateFrame.width > 0 {
            var p = NSPoint(x: candidateFrame.minX, y: candidateFrame.minY - size.height - 8)
            if p.y < visible.minY + 4 { p.y = candidateFrame.maxY + 8 } // 下方没空间 → 上方
            p.y = min(p.y, visible.maxY - size.height - 4)
            p.x = min(max(p.x, visible.minX + 4), max(visible.minX + 4, visible.maxX - size.width - 4))
            return p
        }
        return NSPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 12) // 右上角
    }
}

// MARK: - 焦点切换(面板生命周期内临时激活本进程)

enum PanelFocus {
    static func activate(_ panel: NSPanel) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFront(nil)
        panel.makeKey()
    }

    static func restore(_ panel: NSPanel) {
        panel.orderOut(nil)
        NSApp.setActivationPolicy(.prohibited)
        NSApp.deactivate() // 焦点还给原应用
    }
}

// MARK: - 剪贴板监听(IME 进程常驻,轮询 changeCount 即全局收录)

final class ClipboardMonitor {
    static let shared = ClipboardMonitor()
    static let maxItems = 50
    static let maxLen = 20_000 // 超长截断,防巨文本拖累面板与落盘

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private(set) var items: [String] = [] // 新的在前

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AFM拼音", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("clipboard-history.json")
    }

    func start() {
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard let s = pb.string(forType: .string), !s.isEmpty else { return } // 只收文本
        let text = String(s.prefix(Self.maxLen))
        guard text != items.first else { return }
        items.removeAll { $0 == text } // 重复复制 → 置顶
        items.insert(text, at: 0)
        if items.count > Self.maxItems { items.removeLast() }
        persist()
        CompanionPanels.clipboard.model.reload(from: items)
        DebugLog.log("剪贴板收录 #\(items.count) 长度=\(text.count)")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return }
        items = list
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

// MARK: - 剪贴板面板

final class ClipboardModel: ObservableObject {
    @Published var items: [String] = [] // 面板最多展示 9 条(数字键直达)
    @Published var selected = 0
    var onPick: ((String) -> Void)?

    func reload(from list: [String]) {
        items = Array(list.prefix(9))
        selected = 0
    }

    func pick(_ index: Int) -> String? {
        guard items.indices.contains(index) else { return nil }
        selected = index
        return items[index]
    }

    func pickSelected() -> String? { items.isEmpty ? nil : items[min(selected, items.count - 1)] }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
    }
}

struct ClipboardBarView: View {
    @ObservedObject var model: ClipboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if model.items.isEmpty {
                Text("剪贴板是空的 — 在任意应用复制文本后自动收录")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 10)
            } else {
                ForEach(Array(model.items.enumerated()), id: \.offset) { i, text in
                    HStack(spacing: 7) {
                        Text("\(i + 1)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 9)
                        Text(text.replacingOccurrences(of: "\n", with: "⏎"))
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(i == model.selected ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(.clear))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.onPick?(text) }
                }
            }
            Text("点击或 1-9/⏎ 插入 · ↑↓ 选择 · Esc 关闭")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 3).padding(.bottom, 4)
        }
        .frame(width: 340)
        .padding(8)
    }
}

final class ClipboardPanelController {
    private(set) var panel: NSPanel?
    private var hosting: NSHostingView<ClipboardBarView>?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    let model = ClipboardModel()

    var isVisible: Bool { panel?.isVisible ?? false }

    func open(caret: NSRect, candidateFrame: NSRect) {
        let panel = ensurePanel()
        model.reload(from: ClipboardMonitor.shared.items)
        model.onPick = { [weak self] text in
            self?.close() // 先还焦点,再插入到原应用光标处
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                InputController.insertFromPanel(text)
            }
        }
        reposition(caret: caret, candidateFrame: candidateFrame)
        PanelFocus.activate(panel)
        installMonitors()
    }

    func close() {
        guard panel != nil else { return }
        tearDownMonitors()
        PanelFocus.restore(panel!)
    }

    func reposition(caret: NSRect, candidateFrame: NSRect) {
        guard let panel, panel.isVisible, let hosting else { return }
        let size = hosting.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(CompanionPanels.origin(size: size, caret: caret, candidateFrame: candidateFrame))
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        let host = NSHostingView(rootView: ClipboardBarView(model: model))
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 18
            glass.contentView = host
            p.contentView = glass
        } else {
            p.contentView = host
        }
        hosting = host
        panel = p
        return p
    }

    private func installMonitors() {
        tearDownMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, self.isVisible, NSApp.keyWindow === self.panel else { return ev }
            let mods = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if ev.keyCode == 53 || (ev.keyCode == 9 && mods.contains(.control)) { // Esc / ⌃V
                self.close(); return nil
            }
            if ev.keyCode == 3 && mods.contains(.control) { // ⌃F → 切到翻译面板
                self.close()
                CompanionPanels.toggleTranslate()
                return nil
            }
            switch ev.keyCode {
            case 125: self.model.move(1); return nil  // ↓
            case 126: self.model.move(-1); return nil // ↑
            case 36:                                  // ⏎ 插入高亮项
                if let t = self.model.pickSelected() { self.model.onPick?(t) }
                return nil
            default:
                if mods.subtracting(.shift).isEmpty,
                   let d = ev.charactersIgnoringModifiers?.first?.wholeNumberValue, (1...9).contains(d),
                   let t = self.model.pick(d - 1) {
                    self.model.onPick?(t)
                    return nil
                }
            }
            return ev
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            self?.close() // 点回别的应用即收起
        }
    }

    private func tearDownMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }
}

// MARK: - 翻译面板

final class TranslateModel: ObservableObject {
    @Published var input = ""
    @Published var result = ""
    @Published var translating = false
    @Published var focusToken = 0
    var onInsert: ((String) -> Void)?

    /// 方向自动: 含中文 → 译英,否则 → 译中
    var direction: String {
        if input.trimmingCharacters(in: .whitespaces).isEmpty { return "自动" }
        let hasCJK = input.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        return hasCJK ? "中 → 英" : "英 → 中"
    }

    func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !translating else { return }
        translating = true
        result = ""
        Task {
            let out = await FMReranker.shared.translate(text)
            translating = false
            result = out ?? "翻译失败 — FM 不可用或未输出结果"
        }
    }
}

struct TranslateBarView: View {
    @ObservedObject var model: TranslateModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("翻译").font(.system(size: 13, weight: .semibold))
                Text(model.direction).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if model.translating { ProgressView().controlSize(.small) }
            }
            TextField("输入要翻译的文本,⏎ 翻译", text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(3)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 9).fill(.primary.opacity(0.06)))
                .onSubmit { model.submit() }
                .focused($focused)
            if !model.result.isEmpty {
                Text(model.result)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    chip("插入到光标") { model.onInsert?(model.result) }
                    chip("复制") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(model.result, forType: .string)
                    }
                    Spacer()
                }
            }
            Text("⏎ 翻译 · 轻点 Shift 切英文模式可输英文 · Esc 关闭")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(width: 360)
        .padding(10)
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { _ in focused = true }
    }

    private func chip(_ label: String, action: @escaping () -> Void) -> some View {
        Text(label)
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(.primary.opacity(0.10)))
            .contentShape(Capsule())
            .onTapGesture(perform: action)
    }
}

final class TranslatePanelController {
    private(set) var panel: NSPanel?
    private var hosting: NSHostingView<TranslateBarView>?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    let model = TranslateModel()

    var isVisible: Bool { panel?.isVisible ?? false }

    func open(caret: NSRect, candidateFrame: NSRect) {
        let panel = ensurePanel()
        model.onInsert = { [weak self] text in
            self?.close() // 先还焦点,再插入到原应用光标处
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                InputController.insertFromPanel(text)
            }
        }
        reposition(caret: caret, candidateFrame: candidateFrame)
        PanelFocus.activate(panel)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.model.focusToken &+= 1 // 触发 @FocusState 聚焦输入框
        }
        installMonitors()
    }

    func close() {
        guard panel != nil else { return }
        tearDownMonitors()
        PanelFocus.restore(panel!)
    }

    func reposition(caret: NSRect, candidateFrame: NSRect) {
        guard let panel, panel.isVisible, let hosting else { return }
        let size = hosting.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(CompanionPanels.origin(size: size, caret: caret, candidateFrame: candidateFrame))
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        let host = NSHostingView(rootView: TranslateBarView(model: model))
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 18
            glass.contentView = host
            p.contentView = glass
        } else {
            p.contentView = host
        }
        hosting = host
        panel = p
        return p
    }

    private func installMonitors() {
        tearDownMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, self.isVisible, NSApp.keyWindow === self.panel else { return ev }
            let mods = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if ev.keyCode == 53 || (ev.keyCode == 3 && mods.contains(.control)) { // Esc / ⌃F
                self.close(); return nil
            }
            if ev.keyCode == 9 && mods.contains(.control) { // ⌃V → 切到剪贴板面板
                self.close()
                CompanionPanels.toggleClipboard()
                return nil
            }
            return ev // 其余按键(含输入法组词)全交给输入框
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            self?.close() // 点回别的应用即收起
        }
    }

    private func tearDownMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }
}
