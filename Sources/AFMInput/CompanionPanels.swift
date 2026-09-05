import AppKit
import SwiftUI
import IMECore

// 伴随面板(⌃V 剪贴板 / ⌃F 翻译): 液态玻璃,候选条在 → 浮其下方(放不下 → 上方),
// 候选条不在 → 光标所在屏幕右上角。两面板可并存:剪贴板贴候选条左缘、翻译贴右缘,重叠时翻译挪到剪贴板右侧。
// 焦点模型(踩坑修正,详见 AGENTS.md):
//  - 剪贴板面板【免激活】:canBecomeKey=false 的纯展示面板,本进程保持 .prohibited 不抢焦点,
//    客户端焦点/组词/候选条原样存活,打字可继续;键盘选词由 InputController.handle 路由(组词中按键归组词,面板用点击)。
//  - 翻译面板需要键盘,必须临时 .accessory 激活;组词中打开 → InputController.suspendCompositionForPanel
//    挂起(deactivateServer 跳过提交),关闭还焦点后 activateServer 原样恢复预编辑态与候选条。
//  - 面板激活后自有 app 的事件仍回流 IMK handle(实测)→ handle 顶部 anyKeyWindow 全放行,
//    翻译框才能收到原始按键(此前字母被拼音引擎吞掉,表现为「翻译框无法输入」)。

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
        clipboard.open(caret: InputController.latestCaret, candidateFrame: InputController.latestCandidateFrame)
    }

    static func toggleTranslate() {
        if translate.isVisible { translate.close(); return }
        translate.open(caret: InputController.latestCaret, candidateFrame: InputController.latestCandidateFrame)
    }

    /// 候选窗显示/移动/隐藏时同步重浮(latestCandidateFrame 由 InputController 经 onFrameChange 回写)
    static func repositionAll() {
        let caret = InputController.latestCaret
        let cand = InputController.latestCandidateFrame
        clipboard.reposition(caret: caret, candidateFrame: cand)
        translate.reposition(caret: caret, candidateFrame: cand)
        resolveOverlap()
    }

    /// 双面板并存防重叠: 翻译面板移到剪贴板右侧,右侧放不下 → 剪贴板下方
    static func resolveOverlap() {
        guard clipboard.isVisible, translate.isVisible,
              let cb = clipboard.panel?.frame, let tr = translate.panel?.frame, cb.intersects(tr) else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(cb) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? cb
        var p = NSPoint(x: cb.maxX + 8, y: min(tr.minY, cb.minY))
        if p.x + tr.width > visible.maxX - 4 { p = NSPoint(x: cb.minX, y: cb.minY - tr.height - 8) }
        p.x = min(max(p.x, visible.minX + 4), visible.maxX - tr.width - 4)
        p.y = min(max(p.y, visible.minY + 4), visible.maxY - tr.height - 4)
        translate.panel?.setFrameOrigin(p)
    }

    /// 通用定位: 候选条下方(剪贴板贴左缘/翻译贴右缘),放不下 → 上方;无候选条 → 光标所在屏幕右上角
    static func origin(size: NSSize, caret: NSRect, candidateFrame: NSRect, side: PanelSide) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(caret) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if !candidateFrame.isNull, candidateFrame.width > 0 {
            let x0 = side == .left ? candidateFrame.minX : candidateFrame.maxX - size.width
            var p = NSPoint(x: x0, y: candidateFrame.minY - size.height - 8)
            if p.y < visible.minY + 4 { p.y = candidateFrame.maxY + 8 } // 下方没空间 → 上方
            p.y = min(p.y, visible.maxY - size.height - 4)
            p.x = min(max(p.x, visible.minX + 4), max(visible.minX + 4, visible.maxX - size.width - 4))
            return p
        }
        return NSPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 12) // 右上角
    }
}

enum PanelSide { case left, right }

// MARK: - 焦点切换(仅翻译面板用;面板生命周期内临时激活本进程)

enum PanelFocus {
    static func activate(_ panel: NSPanel) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
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
            Text("点击或 1-9/⏎ 插入 · ↑↓ 选择 · Esc/⌃V 关闭 · 组词中请用点击")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 3).padding(.bottom, 4)
        }
        .frame(width: 340)
        .padding(8)
    }
}

/// 永不持键的面板(剪贴板用): 点击可用,但绝不成为 keyWindow——客户端焦点与组词不受任何影响
final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

final class ClipboardPanelController {
    private(set) var panel: NSPanel?
    private var hosting: NSHostingView<ClipboardBarView>?
    private var clickMonitor: Any?
    let model = ClipboardModel()

    var isVisible: Bool { panel?.isVisible ?? false }

    func open(caret: NSRect, candidateFrame: NSRect) {
        let panel = ensurePanel()
        model.reload(from: ClipboardMonitor.shared.items)
        model.onPick = { [weak self] text in self?.pick(text) }
        reposition(caret: caret, candidateFrame: candidateFrame)
        panel.orderFront(nil) // 免激活: 不抢焦点,组词/候选条/打字全部原样存活
        installClickOutsideMonitor()
    }

    func close() {
        guard panel != nil else { return }
        removeClickOutsideMonitor()
        panel?.orderOut(nil) // 从未激活,无需还焦点/改激活策略
    }

    /// 选中插入(点击/键盘共用): 组词中先按空格语义上屏首选再插入(客户端仍持焦点,立即执行)
    func pick(_ text: String) {
        close()
        InputController.insertFromPanel(text)
    }

    /// 键盘路由(InputController.handle 在客户端持焦点时调用,仅非组词中): 返回 true = 已消费
    func routeKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: close(); return true          // Esc 关闭
        case 125: model.move(1); return true   // ↓
        case 126: model.move(-1); return true  // ↑
        case 36:                               // ⏎ 插入高亮项
            if let t = model.pickSelected() { pick(t) }
            return true
        default:
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods.subtracting(.capsLock).isEmpty,
                  let c = event.charactersIgnoringModifiers?.first?.wholeNumberValue,
                  (1...9).contains(c), let t = model.pick(c - 1) else { return false }
            pick(t)
            return true
        }
    }

    func reposition(caret: NSRect, candidateFrame: NSRect) {
        guard let panel, panel.isVisible, let hosting else { return }
        let size = hosting.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(CompanionPanels.origin(size: size, caret: caret, candidateFrame: candidateFrame, side: .left))
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NonKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
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

    /// 点到面板外即收起(免激活面板没有 resignKey 时机;全局监听只观察不消费,不影响点击本身)
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self, self.isVisible, let panel = self.panel else { return }
            if !panel.frame.contains(NSEvent.mouseLocation) { self.close() }
        }
    }

    private func removeClickOutsideMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
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
            Text("⏎ 翻译 · 字母直接键入,中文 ⌘V 粘贴 · Esc 关闭")
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
        PanelFocus.activate(panel) // 翻译框需要键盘,必须临时激活(组词已由 suspendCompositionForPanel 挂起)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.model.focusToken &+= 1 // 触发 @FocusState 聚焦输入框
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
            guard let self, self.isVisible, NSApp.keyWindow !== self.panel else { return }
            self.model.focusToken &+= 1 // 激活竞态兜底:仍未持键再聚焦一次
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
        panel.setFrameOrigin(CompanionPanels.origin(size: size, caret: caret, candidateFrame: candidateFrame, side: .right))
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
            if ev.keyCode == 9 && mods.contains(.control) { // ⌃V → 剪贴板面板并存打开(不关翻译)
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
