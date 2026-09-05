import AppKit
import SwiftUI
import IMECore

// MARK: - 候选条 SwiftUI 视图(参考 macOS 26 候选窗样式)
//
// 三种展示态:
//  - 候选条(默认): 8 个滑动窗口,←→ 移动选中,越过边缘时队首滑出/新候选滑入(队列式动画);
//    选中态 = 透明液态玻璃水滴(Kyant0 AndroidLiquidGlass LiquidBottomTabs 同款思路):
//    折射 = Core Image kernel(DropletLens,AGSL lens 逐行移植)作用于幽灵行快照(强调色层),
//    水滴本体 = 玻璃胶囊(26+ glassEffect / <26 白色半透明),按住可拖,松手吸附上屏
//  - 网格(↓ 展开): 8 列固定 × 上下滑动窗口(4 行),↑/←→ 移回首行(前 8 个)自动收起
//  - 内联翻译(⌃F): 单行显示当前高亮候选的译文,空格上屏
// 注意: 不用 @State/@StateObject 等宏属性包装器(CLT 无 SwiftUIMacros 插件);
// 水滴几何/渲染状态全在 CandidateDropletModel(@Published 非宏,视图直写局部刷新)。

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

/// 水滴几何与渲染模型(视图直写 @Published 局部刷新,不经 props 每帧往返 InputController)。
/// frames = 各候选 cell frame("candBar" 坐标,点;OnGeometryChange 回写);
/// 拖拽期间不滑窗口(钳制在可见 8 个内)——rootView 重建会中断进行中的手势。
final class CandidateDropletModel: ObservableObject {
    /// 单例(面板/覆盖层/控制器多视图引用同一份几何与折射输出)
    static let shared = CandidateDropletModel()

    // 布局输入(show 时由控制器更新)
    private(set) var windowStart = 0
    private(set) var itemCount = 0
    private(set) var barGlassHeight: CGFloat = 44 // 玻璃条高度(点)
    private(set) var selectedIndex = 0
    var snapshotScale: CGFloat = 2                // 幽灵行快照倍率
    var onDrop: ((Double) -> Void)?               // 松手:连续全局下标 → 吸附上屏

    // 几何输入(cell frame 回写)
    @Published var frames: [Int: CGRect] = [:]
    @Published var rowFrame: CGRect = .null       // cells HStack frame(同坐标)

    // 交互态
    @Published var dragFraction: Double? = nil    // 拖拽中的连续全局下标(nil = 非拖拽)
    @Published var press: Double = 0              // 按压进度 0-1
    @Published var velocity: Double = 0           // 平滑拖拽速度(归一,驱动挤压拉伸)

    // 产出(overlay 直接渲染)
    @Published var blobFrame: CGRect? = nil       // 水滴最终 frame(含缩放/挤压)
    @Published var lensImage: CGImage? = nil      // CI 折射输出(仅按压中)
    var lensScale: CGFloat = 2
    /// 网格/翻译/占位等非候选条形态:水滴整体隐藏
    var suppressed = false

    // 幽灵行快照(内部;控制器经 ImageRenderer 重拍)
    var ghostImage: CGImage?

    func applyLayout(count: Int, windowStart: Int, barGlassHeight: CGFloat, selectedIndex: Int) {
        self.itemCount = count
        self.windowStart = windowStart
        self.barGlassHeight = barGlassHeight
        self.selectedIndex = selectedIndex
        recompute()
    }

    func setSelectedIndex(_ idx: Int) {
        selectedIndex = idx
        recompute()
    }

    func reset() {
        dragFraction = nil
        press = 0
        velocity = 0
        recompute()
    }

    func noteCellFrame(_ index: Int, _ frame: CGRect) {
        frames[index] = frame
        recompute()
    }

    func noteRowFrame(_ frame: CGRect) {
        rowFrame = frame
    }

    // MARK: 交互

    func beginDrag(atX x: CGFloat, fallback: Int) {
        press = 1
        velocity = 0
        dragFraction = fraction(at: x) ?? Double(fallback)
        recompute()
    }

    func drag(by dx: CGFloat) {
        guard let base = dragFraction, let f = currentCellFrame, f.width > 1 else { return }
        let target = base + Double(dx) / Double(f.width)
        let lo = Double(windowStart)
        let hi = Double(max(windowStart, min(windowStart + 7, itemCount - 1)))
        let clamped = max(lo, min(hi, target))
        let inst = (clamped - base) * 3.0
        velocity = velocity * 0.65 + max(-1, min(1, inst)) * 0.35
        dragFraction = clamped
        recompute()
    }

    func endDrag() {
        let f = dragFraction ?? Double(selectedIndex)
        press = 0
        velocity = 0
        dragFraction = nil
        recompute()
        onDrop?(f)
    }

    // MARK: 几何与渲染

    private var windowIndices: Range<Int> {
        windowStart..<min(windowStart + 8, max(windowStart, itemCount))
    }

    private var currentCellFrame: CGRect? {
        dragFraction.flatMap { interpolatedFrame(at: $0) }
    }

    /// 水滴锚定下标(拖拽中随手指,平时 = 选中项)
    private var activeIndex: Int {
        dragFraction.map { max(0, min(itemCount - 1, Int($0.rounded()))) } ?? selectedIndex
    }

    /// 连续下标 → cell frame 插值(候选宽度不一,按实际 frame 线性插)
    private func interpolatedFrame(at f: Double) -> CGRect? {
        let keys = windowIndices.filter { frames[$0] != nil }
            .sorted { frames[$0]!.minX < frames[$1]!.minX }
        guard let firstKey = keys.first, let firstFrame = frames[firstKey] else { return nil }
        func frame(_ i: Int) -> CGRect? {
            guard let fr = frames[i], fr.width > 0, fr.height > 0 else { return nil }
            return fr
        }
        if f <= Double(firstKey) { return firstFrame }
        if let lastKey = keys.last, let lastFrame = frame(lastKey), f >= Double(lastKey) { return lastFrame }
        let i0 = Int(floor(f))
        guard let a = frame(i0), let b = frame(i0 + 1) else { return firstFrame }
        let t = f - Double(i0)
        let x = a.minX + (b.minX - a.minX) * t
        let w = a.width + (b.width - a.width) * t
        return CGRect(x: x, y: a.minY, width: w, height: max(a.height, b.height))
    }

    /// 候选条 x 坐标 → 连续全局下标(按 cell 中心分段线性)
    private func fraction(at x: CGFloat) -> Double? {
        let keys = windowIndices.filter { frames[$0] != nil }
            .sorted { frames[$0]!.minX < frames[$1]!.minX }
        guard let first = keys.first, let last = keys.last else { return nil }
        if x <= frames[first]!.midX { return Double(first) }
        if x >= frames[last]!.midX { return Double(last) }
        for k in 0..<(keys.count - 1) {
            let a = keys[k], b = keys[k + 1]
            let ca = frames[a]!.midX, cb = frames[b]!.midX
            if x >= ca, x <= cb, cb > ca {
                return Double(a) + Double((x - ca) / (cb - ca))
            }
        }
        return Double(first)
    }

    /// 重算水滴几何(总是)+ 折射图(仅按压中)
    func recompute() {
        guard !suppressed,
              let cell = interpolatedFrame(at: dragFraction ?? Double(selectedIndex)) else {
            blobFrame = nil
            lensImage = nil
            return
        }
        // 静止尺寸: 高度 ≈ 0.875×玻璃条(Kyant0 水滴 56/条 64),宽 = cell + 6
        let restH = min(barGlassHeight * 0.875, barGlassHeight - 2)
        let restW = cell.width + 6
        let rest = CGRect(x: cell.midX - restW / 2, y: cell.midY - restH / 2, width: restW, height: restH)
        // 按压放大 1.35×(Kyant0 pressedScale 78/56)+ 速度挤压拉伸(layerBlock 同款公式)
        let pressScale = 1 + 0.35 * press
        let v = max(-1, min(1, velocity))
        let sx = pressScale / (1 - max(-0.2, min(0.2, v * 0.075)))
        let sy = pressScale * (1 - max(-0.2, min(0.2, v * 0.025)))
        let blob = rest.scaledAboutCenter(sx: sx, sy: sy)
        blobFrame = blob

        // 折射: 仅按压中(Kyant0 lens(10dp*progress, 14dp*progress);静止时内容直接透过玻璃)
        if press > 0, let ghost = ghostImage, rowFrame.width > 0 {
            let scale = snapshotScale
            let rectInImage = CGRect(
                x: (blob.minX - rowFrame.minX) * scale,
                y: (blob.minY - rowFrame.minY) * scale,
                width: blob.width * scale,
                height: blob.height * scale)
            lensImage = DropletLens.render(ghost: ghost, rect: rectInImage,
                                           refraction: (h: 10 * press * scale, amount: -14 * press * scale))
            lensScale = scale
        } else {
            lensImage = nil
        }
    }
}

private extension CGRect {
    func scaledAboutCenter(sx: CGFloat, sy: CGFloat) -> CGRect {
        CGRect(x: midX - width * sx / 2, y: midY - height * sy / 2, width: width * sx, height: height * sy)
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

    // MARK: 候选条(滑动窗口;水滴渲染在面板层 DropletOverlayView,这里只管内容与手势)

    private var barView: some View {
        let end = min(windowStart + 8, items.count)
        let window = windowStart < end ? Array(items[windowStart..<end]) : []
        return HStack(spacing: 3) {
            ForEach(window) { item in
                CandidateCell(item: item,
                              number: item.isAI ? "\u{F8FF}" : "\(item.index - windowStart + 1)",
                              active: item.index == selectedIndex)
                    .onTapGesture { onSelect(item.index) }
                    .transition(Self.slideTransition(forward: slideForward))
                    .modifier(FrameReporter(index: item.index, model: droplet))
            }
            expandChevron("▾")
        }
        .modifier(RowFrameReporter(model: droplet))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: windowStart)
        .coordinateSpace(name: "candBar")
        .contentShape(Rectangle())
        .gesture(dragGesture)
    }

    /// 按住即抓起水滴(跳到按压处的候选),左右拖连续跟手(钳制在可见窗口内,不滑窗口防手势中断);
    /// 松手吸附最近候选并上屏(轻点 = 位移 0 的拖拽,与点选一致)
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                if droplet.dragFraction == nil {
                    droplet.beginDrag(atX: v.startLocation.x, fallback: selectedIndex)
                } else {
                    droplet.drag(by: v.location.x - v.startLocation.x)
                }
            }
            .onEnded { _ in droplet.endDrag() }
    }

    /// 幽灵行快照内容(强调色样式,与正常行逐像素同布局;ImageRenderer 离屏渲染用)
    static func ghostSnapshotRow(items: [CandidateItem], windowStart: Int) -> some View {
        let end = min(windowStart + 8, items.count)
        let window = windowStart < end ? Array(items[windowStart..<end]) : []
        return HStack(spacing: 3) {
            ForEach(window) { item in
                CandidateCell(item: item,
                              number: item.isAI ? "\u{F8FF}" : "\(item.index - windowStart + 1)",
                              active: true, ghost: true)
            }
        }
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
struct FrameReporter: ViewModifier {
    let index: Int
    let model: CandidateDropletModel

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named("candBar")) } action: { _, new in
                model.noteCellFrame(index, new) // 写 @Published 触发水滴重算(布局本身不变,无循环)
            }
        } else {
            content
        }
    }
}

/// 行 frame 回写(CI 折射的坐标映射基准)
struct RowFrameReporter: ViewModifier {
    let model: CandidateDropletModel

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named("candBar")) } action: { _, new in
                model.noteRowFrame(new)
            }
        } else {
            content
        }
    }
}

private struct CandidateCell: View {
    let item: CandidateItem
    let number: String
    let active: Bool          // 选中(词加粗)
    var ghost = false         // 幽灵快照样式(强调色,仅水滴折射内可见)
    var gridCell = false

    var body: some View {
        HStack(spacing: 4) {
            Text(number)
                .font(.system(size: gridCell ? 10 : 11, weight: .semibold))
                .foregroundStyle(ghost
                    ? AnyShapeStyle(.cyan)
                    : (item.isAI ? AnyShapeStyle(.cyan) : AnyShapeStyle(.secondary)))
                .frame(width: gridCell ? 16 : 9)
                .baselineOffset(-1)
            Text(item.text)
                .font(.system(size: gridCell ? 14 : 16, weight: (active || ghost) ? .semibold : .regular))
                .foregroundStyle(.primary)
                .fixedSize()
                .lineLimit(1)
        }
        .padding(.horizontal, gridCell ? 6 : 10)
        .padding(.vertical, gridCell ? 4 : 7)
        .frame(minWidth: gridCell ? 62 : 0, alignment: .leading)
    }
}

/// 水滴覆盖层(独立于玻璃条的宿主视图,可胀出条外;hitTest 全透传,事件归下层候选条)
struct DropletOverlayView: View {
    @ObservedObject var model: CandidateDropletModel
    var marginH: CGFloat
    var marginV: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let f = model.blobFrame {
                blob(f)
                if let img = model.lensImage {
                    Image(img, scale: model.lensScale, orientation: .up, label: Text(""))
                        .frame(width: f.width, height: f.height)
                        .offset(x: f.minX, y: f.minY)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .offset(x: marginH, y: marginV) // 宿主覆盖全面板,内容坐标为玻璃条内坐标
        .allowsHitTesting(false)
    }

    @ViewBuilder private func blob(_ f: CGRect) -> some View {
        let material = Group {
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular.interactive(), in: Capsule())
            } else {
                Capsule().fill(.white.opacity(0.22))
            }
        }
        .frame(width: f.width, height: f.height)
        .overlay {
            Capsule().fill(.white.opacity(0.08 * model.press)) // Kyant0 onDrawSurface 容器色
        }
        .overlay {
            Capsule().stroke(
                LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
                .opacity(0.3 + 0.5 * model.press) // 上缘高光
        }
        .shadow(color: .black.opacity(0.22 * model.press), radius: 4 + 3 * model.press, y: 2)
        .offset(x: f.minX, y: f.minY)
        material
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

// MARK: - 液态玻璃候选窗(NSPanel)

/// 结构(为水滴"胀出条外"预留边距): 面板 = 容器(透明,含边距)
///   ├─ 玻璃视窗(NSGlassEffectView,26+;即候选条本体矩形) / <26 直接放宿主
///   │    └─ 候选条宿主(SwiftUI: 滑动窗口内容 + 手势)
///   └─ 水滴覆盖宿主(全面板,SwiftUI 玻璃胶囊 + CI 折射图;hitTest 全透传)
/// onFrameChange 回报**玻璃条矩形**(伴随面板定位锚点)。
final class CandidateWindowController {
    static let marginH: CGFloat = 10
    static let marginV: CGFloat = 12

    private var panel: NSPanel?
    private var containerView: NSView?
    private var glassView: NSView?
    private var barHosting: NSHostingView<CandidateBarView>?
    private var overlayHosting: NSHostingView<DropletOverlayView>?
    private var onSelect: (Int) -> Void = { _ in }
    private var onToggleExpand: () -> Void = {}
    private var lastGhostKey = ""

    /// 候选窗玻璃条 frame 变化回调(nil = 隐藏);伴随面板据此重新浮动定位
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

        let barRoot = CandidateBarView(
            items: [], selectedIndex: 0, windowStart: 0, slideForward: true,
            expanded: false, rowStart: 0, rowSlideDown: true, translation: nil, isLoading: false,
            droplet: CandidateDropletModel.shared,
            onSelect: { [weak self] idx in self?.onSelect(idx) },
            onToggleExpand: { [weak self] in self?.onToggleExpand() })
        let barHost = NSHostingView(rootView: barRoot)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        container.wantsLayer = true
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 22
            glass.contentView = barHost
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = true
            }
            container.addSubview(glass)
            glassView = glass
        } else {
            container.addSubview(barHost)
            glassView = nil
        }
        let overlay = PassthroughHostingView(rootView: DropletOverlayView(
            model: InputController.dropletModel,
            marginH: Self.marginH, marginV: Self.marginV))
        container.addSubview(overlay)

        p.contentView = container
        containerView = container
        barHosting = barHost
        overlayHosting = overlay
        panel = p
        return p
    }

    /// 显示/刷新候选窗。caretRect: 屏幕坐标矩形(AppKit 底左原点);null 时回退底部居中。
    func show(items: [CandidateItem], selectedIndex: Int, windowStart: Int, slideForward: Bool,
              expanded: Bool, rowStart: Int, rowSlideDown: Bool,
              translation: TranslationDisplay?, isLoading: Bool = false,
              droplet: CandidateDropletModel,
              caretRect: NSRect, onSelect: @escaping (Int) -> Void,
              onToggleExpand: @escaping () -> Void = {}) {
        let panel = ensurePanel()
        self.onSelect = onSelect
        self.onToggleExpand = onToggleExpand
        guard let host = barHosting, let container = containerView else { return }

        host.rootView = CandidateBarView(
            items: items, selectedIndex: selectedIndex,
            windowStart: windowStart, slideForward: slideForward,
            expanded: expanded, rowStart: rowStart, rowSlideDown: rowSlideDown,
            translation: translation, isLoading: isLoading, droplet: droplet,
            onSelect: { [weak self] idx in self?.onSelect(idx) },
            onToggleExpand: { [weak self] in self?.onToggleExpand() })

        let barSize = host.fittingSize
        let panelSize = NSSize(width: barSize.width + Self.marginH * 2,
                               height: barSize.height + Self.marginV * 2)
        panel.setContentSize(panelSize)
        container.frame = NSRect(origin: .zero, size: panelSize)
        let barRect = NSRect(x: Self.marginH, y: Self.marginV, width: barSize.width, height: barSize.height)
        (glassView ?? barHosting)?.frame = barRect
        overlayHosting?.frame = container.bounds

        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // 先按玻璃条矩形定位(伴随面板锚点同款),再换算回面板原点
        var barOrigin: NSPoint
        if caretRect.isNull {
            barOrigin = NSPoint(x: visible.midX - barSize.width / 2, y: visible.minY + 60)
        } else {
            barOrigin = NSPoint(x: caretRect.minX, y: caretRect.minY - barSize.height - 8)
            if barOrigin.y < visible.minY { barOrigin.y = caretRect.maxY + 8 }
            barOrigin.x = min(max(barOrigin.x, visible.minX + 4),
                              max(visible.minX + 4, visible.maxX - barSize.width - 4))
        }
        panel.setFrameOrigin(NSPoint(x: barOrigin.x - Self.marginH, y: barOrigin.y - Self.marginV))
        panel.orderFront(nil)

        // 水滴布局输入 + 幽灵行快照(内容变化才重拍)
        droplet.suppressed = expanded || translation != nil || isLoading
        droplet.applyLayout(count: items.count, windowStart: windowStart,
                            barGlassHeight: barSize.height, selectedIndex: selectedIndex)
        let key = items.map(\.text).joined(separator: "\u{1}") + "|\(windowStart)"
        if key != lastGhostKey, DropletLens.isAvailable {
            lastGhostKey = key
            refreshGhostSnapshot(items: items, windowStart: windowStart)
        }

        let barFrame = panel.frame.offsetBy(dx: Self.marginH, dy: Self.marginV)
        onFrameChange?(NSRect(origin: barFrame.origin, size: barSize))
        DebugLog.log("候选窗显示 bar=\(NSStringFromSize(barSize)) origin=\(NSStringFromPoint(barOrigin)) caret=\(NSStringFromRect(caretRect)) 网格=\(expanded)")
    }

    /// 幽灵行快照(强调色层,CI 折射的内容源;与正常行逐像素同布局)。IMK 回调在主线程,assumeIsolated 满足 ImageRenderer 的隔离要求
    private func refreshGhostSnapshot(items: [CandidateItem], windowStart: Int) {
        let model = CandidateDropletModel.shared
        let scheme: ColorScheme = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        let cg = MainActor.assumeIsolated {
            let renderer = ImageRenderer(content: CandidateBarView
                .ghostSnapshotRow(items: items, windowStart: windowStart)
                .environment(\.colorScheme, scheme))
            renderer.scale = 2
            return renderer.cgImage
        }
        model.ghostImage = cg
        model.snapshotScale = 2
        DebugLog.log("幽灵行快照 \(cg.map { "\($0.width)x\($0.height)" } ?? "失败")")
    }

    func hide() {
        panel?.orderOut(nil)
        onFrameChange?(nil)
    }
}

/// 全透传宿主(水滴覆盖层不接任何事件,归下层候选条)
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
