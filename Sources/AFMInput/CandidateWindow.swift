import AppKit
import SwiftUI
import IMECore

// MARK: - 候选条 SwiftUI 视图(参考 macOS 26 候选窗样式)
//
// 三种展示态:
//  - 候选条(默认): 8 个滑动窗口,←→ 移动选中,越过边缘时队首滑出/新候选滑入(队列式动画);
//    选中态 = 可拖拽的透明液态玻璃水滴(Kyant0 AndroidLiquidGlass LiquidBottomTabs 同款思路):
//    双层内容(正常层 + 强调色幽灵层,幽灵层仅被水滴胶囊遮罩照出)+ glassEffect 水滴本体,
//    鼠标按住拖动水滴连续滑动,松手吸附最近候选并上屏
//  - 网格(↓ 展开): 8 列固定 × 上下滑动窗口(4 行),↑/←→ 移回首行(前 8 个)自动收起
//  - 内联翻译(⌃F): 单行显示当前高亮候选的译文,空格上屏
// 注意: 不用 @State/@StateObject 等 SwiftUI 宏属性包装器——CLT 环境找不到 SwiftUIMacros 插件,
// 窗口状态(候选条起点/网格行起点)由 InputController 持有并以 props 传入;
// 水滴拖拽的连续状态放 CandidateDropletModel(@Published 非宏,视图直写、局部响应,不经 props 往返)。

struct CandidateItem: Identifiable, Equatable {
    var id: Int { index }
    let index: Int      // 全局下标(跨窗口连续)
    let text: String
    let isAI: Bool      // FM 重排提到首位时显示 ✦
}

/// ⌃F 内联翻译态(translating → spinner;text → 译文/失败提示)
struct TranslationDisplay {
    var text: String?
    var translating: Bool
}

/// 水滴拖拽模型(视图直写 @Published 局部刷新;松手回调整个报给 InputController 上屏)。
/// frames = 当前窗口各候选 cell 在候选条坐标系("candBar")的 frame(OnGeometryChange 回写),
/// 拖拽期间不滑窗口(钳制在可见 8 个内)——避免 rootView 重建中断手势。
final class CandidateDropletModel: ObservableObject {
    @Published var dragFraction: Double?    // 拖拽中的全局连续下标(nil = 非拖拽,取 selectedIndex)
    @Published var press: Double = 0        // 按压进度 0-1(驱动水滴放大/加深)
    @Published var velocity: Double = 0     // 平滑拖拽速度(归一化,驱动挤压拉伸)
    @Published var frames: [Int: CGRect] = [:]
    /// 松手:参数为松手时的连续全局下标,由 InputController 吸附取整并上屏
    var onDrop: ((Double) -> Void)?

    func reset() {
        dragFraction = nil
        press = 0
        velocity = 0
    }
}

struct CandidateBarView: View {
    var items: [CandidateItem]      // 全量候选(窗口内切片渲染)
    var selectedIndex: Int
    var windowStart: Int            // 候选条滑动窗口起点
    var slideForward: Bool          // 窗口滑动方向(驱动队列动画方向)
    var expanded: Bool              // ↓ 展开的网格态
    var rowStart: Int               // 网格可见行窗口起点
    var rowSlideDown: Bool          // 网格行滑动方向
    var translation: TranslationDisplay?
    var isLoading: Bool             // 无词典候选时占位,等 FM 整句
    @ObservedObject var droplet: CandidateDropletModel
    var onSelect: (Int) -> Void
    var onToggleExpand: () -> Void  // ▾/▴ 展开收起网格

    // 网格选中格 glassEffectID 流动变形用;@Namespace 非宏包装器,CLT 环境可用
    @Namespace private var glassNS

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text(" 整句预测中")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            } else if let t = translation {
                translationRow(t)
            } else if expanded {
                CandidateGridView(items: items, selectedIndex: selectedIndex,
                                  rowStart: rowStart, slideDown: rowSlideDown, ns: glassNS,
                                  onSelect: onSelect, onCollapse: onToggleExpand)
            } else {
                barView
            }
        }
        .fixedSize(horizontal: true, vertical: false) // 防截断:按内容自然宽度撑开
        .padding(9)
    }

    // MARK: 候选条(滑动窗口 + 可拖拽水滴)

    private var windowIndices: Range<Int> {
        windowStart..<min(windowStart + 8, max(windowStart, items.count))
    }

    /// 水滴当前锚定的下标(拖拽中随手指,平时 = 选中项);驱动词重粗/幽灵层
    private var activeIndex: Int {
        droplet.dragFraction.map { max(0, min(items.count - 1, Int($0.rounded()))) } ?? selectedIndex
    }

    private var barView: some View {
        let end = min(windowStart + 8, items.count)
        let window = windowStart < end ? Array(items[windowStart..<end]) : []
        return ZStack(alignment: .leading) {
            row(window: window, ghost: false)     // 正常层
            if #available(macOS 26.0, *), dropletFrame != nil {
                row(window: window, ghost: true)  // 幽灵层(强调色),只被水滴胶囊照出
                    .mask { dropletShape }
            }
            dropletOverlay
        }
        .coordinateSpace(name: "candBar")
        .contentShape(Rectangle())
        .gesture(dragGesture)
    }

    /// 一行候选(ghost=false 正常样式;ghost=true 强调色样式,结构与正常层逐像素一致保证遮罩对齐)
    private func row(window: [CandidateItem], ghost: Bool) -> some View {
        HStack(spacing: 3) {
            ForEach(window) { item in
                CandidateCell(item: item,
                              number: item.isAI ? "\u{F8FF}" : "\(item.index - windowStart + 1)",
                              active: item.index == activeIndex,
                              ghost: ghost)
                    .onTapGesture { onSelect(item.index) }
                    .transition(Self.slideTransition(forward: slideForward))
                    .modifier(FrameReporter(index: item.index, model: droplet))
            }
            if !ghost { expandChevron("▾") } // 幽灵层不含 ▾
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: windowStart)
    }

    /// 水滴连续 frame:拖拽中在相邻候选 frame 间线性插值(候选宽度不一,按实际 frame 插)
    private var dropletFrame: CGRect? {
        let keys = windowIndices.filter { droplet.frames[$0] != nil }
            .sorted { droplet.frames[$0]!.minX < droplet.frames[$1]!.minX }
        guard let firstKey = keys.first, let lastKey = keys.last,
              let firstFrame = droplet.frames[firstKey] else { return nil }
        func frame(_ i: Int) -> CGRect? {
            guard let f = droplet.frames[i], f.width > 0, f.height > 0 else { return nil }
            return f
        }
        let f = droplet.dragFraction ?? Double(selectedIndex)
        if f <= Double(firstKey) { return firstFrame }
        if let lastFrame = frame(lastKey), f >= Double(lastKey) { return lastFrame }
        let i0 = Int(floor(f))
        guard let a = frame(i0), let b = frame(i0 + 1) else { return firstFrame }
        let t = f - Double(i0)
        let x = a.minX + (b.minX - a.minX) * t
        let w = a.width + (b.width - a.width) * t
        let h = max(a.height, b.height)
        return CGRect(x: x, y: a.minY, width: w, height: h)
    }

    private var dropletShape: some View {
        Capsule()
            .frame(width: dropletFrame?.width ?? 0, height: dropletFrame?.height ?? 0)
            .offset(x: dropletFrame?.minX ?? 0, y: dropletFrame?.minY ?? 0)
    }

    /// 透明水滴本体:玻璃胶囊,按压缩放 1.12×,速度挤压拉伸(Kyant0 同款形变);
    /// <26 回退白色半透明填充
    @ViewBuilder private var dropletOverlay: some View {
        if let f = dropletFrame {
            let squash = max(-0.12, min(0.12, droplet.velocity * 0.25))
            let sx = 1 / (1 - squash)
            let sy = 1 - squash * 0.35
            let pressScale = 1 + 0.12 * droplet.press
            Group {
                if #available(macOS 26.0, *) {
                    Color.clear
                        .glassEffect(.regular.interactive(), in: Capsule())
                } else {
                    Capsule().fill(.white.opacity(0.22))
                }
            }
            .frame(width: f.width, height: f.height)
            .scaleEffect(x: sx * pressScale, y: sy * pressScale)
            .offset(x: f.minX, y: f.minY)
            .shadow(color: .black.opacity(0.18 * droplet.press), radius: 4, y: 2)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: droplet.press)
            .allowsHitTesting(false) // 手势挂在整条上,水滴只做展示
        }
    }

    /// 按住即抓起水滴(跳到按压处的候选),左右拖连续跟手(钳制在可见窗口内,不滑窗口防手势中断);
    /// 松手吸附最近候选并上屏(轻点 = 位移 0 的拖拽,与点选一致)
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                if droplet.dragFraction == nil {
                    withAnimation(.easeOut(duration: 0.15)) { droplet.press = 1 }
                    droplet.dragFraction = fraction(at: v.startLocation.x) ?? Double(selectedIndex)
                    droplet.velocity = 0
                }
                guard let base = droplet.dragFraction, let f = dropletFrame, f.width > 1 else { return }
                let dx = v.location.x - v.startLocation.x
                let target = base + Double(dx) / Double(f.width)
                let lo = Double(windowIndices.first ?? 0)
                let hi = Double(windowIndices.last ?? 0)
                let clamped = max(lo, min(hi, target))
                let inst = (clamped - droplet.dragFraction!) / 1.0
                droplet.velocity = droplet.velocity * 0.7 + inst * 0.3 // 平滑速度(候选/事件)
                droplet.dragFraction = clamped
            }
            .onEnded { _ in
                let f = droplet.dragFraction ?? Double(selectedIndex)
                droplet.press = 0
                droplet.velocity = 0
                droplet.dragFraction = nil
                droplet.onDrop?(f)
            }
    }

    /// 候选条 x 坐标 → 连续全局下标(按各 cell 中心分段线性插值;窗口外钳到边缘)
    private func fraction(at x: CGFloat) -> Double? {
        let keys = windowIndices.filter { droplet.frames[$0] != nil }
            .sorted { droplet.frames[$0]!.minX < droplet.frames[$1]!.minX }
        guard let first = keys.first, let last = keys.last else { return nil }
        let centers = keys.map { (i: $0, c: droplet.frames[$0]!.midX) }
        guard let fc = centers.first, let lc = centers.last else { return nil }
        if x <= fc.c { return Double(first) }
        if x >= lc.c { return Double(last) }
        for k in 0..<(centers.count - 1) {
            let a = centers[k], b = centers[k + 1]
            if x >= a.c, x <= b.c, b.c > a.c {
                return Double(a.i) + Double((x - a.c) / (b.c - a.c))
            }
        }
        return Double(first)
    }

    static func slideTransition(forward: Bool) -> AnyTransition {
        let inEdge: Edge = forward ? .trailing : .leading
        let outEdge: Edge = forward ? .leading : .trailing
        return .asymmetric(insertion: .move(edge: inEdge).combined(with: .opacity),
                           removal: .move(edge: outEdge).combined(with: .opacity))
    }

    private func translationRow(_ t: TranslationDisplay) -> some View {
        HStack(spacing: 8) {
            Text("译")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.cyan)
            if t.translating {
                ProgressView().controlSize(.small)
                Text("翻译中")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                Text(t.text ?? "")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize()
                Text("空格上屏 · ⌃F/Esc 返回候选")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func expandChevron(_ symbol: String) -> some View {
        Text(symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
            .onTapGesture { onToggleExpand() }
    }
}

/// cell frame 回写(onGeometryChange 需 macOS 15+,低版本不回写 → 水滴隐藏回退点选)
private struct FrameReporter: ViewModifier {
    let index: Int
    let model: CandidateDropletModel

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named("candBar")) } action: { _, new in
                model.frames[index] = new // 写 @Published 触发水滴重算(布局本身不变,无循环)
            }
        } else {
            content
        }
    }
}

private struct CandidateCell: View {
    let item: CandidateItem
    let number: String
    let active: Bool          // 水滴当前锚定(词加粗)
    var ghost: Bool = false   // 幽灵层样式(强调色,仅水滴内可见)
    var gridCell = false

    var body: some View {
        let text = Text(item.text)
            .font(.system(size: gridCell ? 14 : 16, weight: active ? .semibold : .regular))
            .foregroundStyle(ghost ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary))
            .fixedSize()
            .lineLimit(1)
        let num = Text(number)
            .font(.system(size: gridCell ? 10 : 11, weight: .semibold))
            .foregroundStyle(ghost
                ? AnyShapeStyle(.cyan)
                : (item.isAI ? AnyShapeStyle(.cyan) : AnyShapeStyle(.secondary)))
            .frame(width: gridCell ? 16 : 9)
            .baselineOffset(-1)
        return HStack(spacing: 4) { num; text }
            .padding(.horizontal, gridCell ? 6 : 10)
            .padding(.vertical, gridCell ? 4 : 7)
            .frame(minWidth: gridCell ? 62 : 0, alignment: .leading)
    }
}

// MARK: - 展开网格(8 列固定 × 上下滑动窗口)

private struct CandidateGridView: View {
    var items: [CandidateItem]
    var selectedIndex: Int
    var rowStart: Int       // 可见行窗口起点(InputController 持有)
    var slideDown: Bool     // 行滑动方向
    var ns: Namespace.ID?   // 选中格玻璃流动变形
    var onSelect: (Int) -> Void
    var onCollapse: () -> Void
    private let cols = 8        // 8 列固定窗口(与 InputController.gridColumns 一致)

    var body: some View {
        VStack(spacing: 5) {
            rowsView
            HStack(spacing: 8) {
                Text("↑↓←→ 移动 · 数字选词 · 点击上屏")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("▴ 收起")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { onCollapse() }
            }
        }
    }

    private var rowsView: some View {
        let allRows = stride(from: 0, to: items.count, by: cols)
            .map { start in Array(items[start..<min(start + cols, items.count)]) }
        guard !allRows.isEmpty else { return AnyView(EmptyView()) }
        let maxStart = max(0, allRows.count - 4) // 4 = 可见行数(与 InputController.gridVisibleRows 一致)
        let first = min(rowStart, maxStart)
        let last = min(first + 3, allRows.count - 1)
        return AnyView(
            glassFlowContainer {
                VStack(spacing: 1) {
                    ForEach(first...last, id: \.self) { r in
                        HStack(spacing: 2) {
                            ForEach(allRows[r]) { item in
                                gridCell(item)
                                    .onTapGesture { onSelect(item.index) }
                            }
                        }
                        .transition(Self.rowTransition(down: slideDown))
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: rowStart)
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selectedIndex)
            }
        )
    }

    private func gridCell(_ item: CandidateItem) -> some View {
        HStack(spacing: 4) {
            Text(item.isAI ? "\u{F8FF}" : "\(item.index + 1)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(item.isAI ? AnyShapeStyle(.cyan) : AnyShapeStyle(.secondary))
                .frame(width: 16)
                .baselineOffset(-1)
            Text(item.text)
                .font(.system(size: 14, weight: item.index == selectedIndex ? .semibold : .regular))
                .foregroundStyle(.primary)
                .fixedSize()
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(minWidth: 62, alignment: .leading)
        .modifier(LiquidGlassPill(selected: item.index == selectedIndex,
                                  id: item.index, ns: ns))
        .contentShape(Rectangle())
    }

    static func rowTransition(down: Bool) -> AnyTransition {
        let inEdge: Edge = down ? .bottom : .top
        let outEdge: Edge = down ? .top : .bottom
        return .asymmetric(insertion: .move(edge: inEdge).combined(with: .opacity),
                           removal: .move(edge: outEdge).combined(with: .opacity))
    }
}

/// 玻璃形状容器(macOS 26+): 让容器内的选中胶囊与其他玻璃形状融合,配合 glassEffectID
/// 实现形状间流动变形;<26 直接渲染
@ViewBuilder fileprivate func glassFlowContainer(@ViewBuilder _ content: () -> some View) -> some View {
    if #available(macOS 26.0, *) {
        GlassEffectContainer(spacing: 4) { content() }
    } else {
        content()
    }
}

/// 网格选中格的液态玻璃胶囊(macOS 26+ 系统 glassEffect,同系统候选窗/工具栏质感;
/// <26 退回白色半透明填充)
private struct LiquidGlassPill: ViewModifier {
    let selected: Bool
    let id: Int
    var ns: Namespace.ID?

    func body(content: Content) -> some View {
        if selected {
            if #available(macOS 26.0, *) {
                if let ns {
                    content.glassEffect(.regular.interactive(), in: Capsule())
                        .glassEffectID(id, in: ns)
                } else {
                    content.glassEffect(.regular.interactive(), in: Capsule())
                }
            } else {
                content.background(Capsule().fill(.white.opacity(0.22)))
            }
        } else {
            content
        }
    }
}

// MARK: - 液态玻璃候选窗(NSPanel + NSGlassEffectView)

/// 非激活 NSPanel,不抢焦点;NSGlassEffectView 提供真·液态玻璃(暗色/亮色自适应);
/// 内容为 SwiftUI 候选条/网格;跟随光标定位。玻璃效果需要 macOS 26+,低版本退化为普通视图。
final class CandidateWindowController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<CandidateBarView>?
    private var onSelect: (Int) -> Void = { _ in }
    private var onToggleExpand: () -> Void = {}

    /// 候选窗 frame 变化回调(nil = 隐藏);伴随面板(剪贴板/翻译)据此重新浮动定位
    var onFrameChange: ((NSRect?) -> Void)?
    var currentFrame: NSRect { panel?.frame ?? NSRect.null }

    var isVisible: Bool { panel?.isVisible ?? false }

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
        p.becomesKeyOnlyIfNeeded = true

        let host = NSHostingView(rootView: CandidateBarView(
            items: [], selectedIndex: 0, windowStart: 0, slideForward: true,
            expanded: false, rowStart: 0, rowSlideDown: true, translation: nil, isLoading: false,
            droplet: CandidateDropletModel(),
            onSelect: { [weak self] idx in self?.onSelect(idx) },
            onToggleExpand: { [weak self] in self?.onToggleExpand() }))
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 22
            glass.contentView = host
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = true
                DebugLog.log("候选窗: NSGlassEffectView (27 交互式玻璃)")
            } else {
                DebugLog.log("候选窗: NSGlassEffectView (26)")
            }
            p.contentView = glass
        } else {
            DebugLog.log("候选窗: 无玻璃(系统 <26),普通视图")
            p.contentView = host
        }
        hostingView = host
        panel = p
        return p
    }

    /// 显示/刷新候选窗。caretRect: 屏幕坐标矩形(AppKit 底左原点);null 时回退底部居中。
    /// isLoading 且 items 为空时显示 FM 占位。droplet: 水滴拖拽模型(InputController 持有)。
    func show(items: [CandidateItem], selectedIndex: Int, windowStart: Int, slideForward: Bool,
              expanded: Bool, rowStart: Int, rowSlideDown: Bool,
              translation: TranslationDisplay?, isLoading: Bool = false,
              droplet: CandidateDropletModel,
              caretRect: NSRect, onSelect: @escaping (Int) -> Void,
              onToggleExpand: @escaping () -> Void = {}) {
        let panel = ensurePanel()
        self.onSelect = onSelect
        self.onToggleExpand = onToggleExpand
        guard let host = hostingView else { return }

        host.rootView = CandidateBarView(
            items: items, selectedIndex: selectedIndex,
            windowStart: windowStart, slideForward: slideForward,
            expanded: expanded, rowStart: rowStart, rowSlideDown: rowSlideDown,
            translation: translation, isLoading: isLoading, droplet: droplet,
            onSelect: { [weak self] idx in self?.onSelect(idx) },
            onToggleExpand: { [weak self] in self?.onToggleExpand() })

        let size = host.fittingSize
        panel.setContentSize(size)

        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var origin: NSPoint
        if caretRect.isNull {
            // 客户端没给光标矩形:回退到屏幕底部居中
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 60)
        } else {
            origin = NSPoint(x: caretRect.minX, y: caretRect.minY - size.height - 8)
            if origin.y < visible.minY { origin.y = caretRect.maxY + 8 }
            origin.x = min(max(origin.x, visible.minX + 4), max(visible.minX + 4, visible.maxX - size.width - 4))
        }
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)
        onFrameChange?(panel.frame)
        DebugLog.log("候选窗显示 size=\(NSStringFromSize(size)) origin=\(NSStringFromPoint(origin)) caret=\(NSStringFromRect(caretRect)) 网格=\(expanded)")
    }

    func hide() {
        panel?.orderOut(nil)
        onFrameChange?(nil)
    }
}
