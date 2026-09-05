import AppKit
import SwiftUI
import IMECore

// MARK: - 候选条 SwiftUI 视图(参考 macOS 26 候选窗样式)
//
// 三种展示态:
//  - 候选条(默认): 9 个滑动窗口,←→ 移动选中,越过边缘时队首滑出/新候选滑入(队列式动画)
//  - 网格(↓ 展开): 8 列固定 × 上下滑动窗口(4 行),↑/←→ 移回首行(前 8 个)自动收起
//  - 内联翻译(⌃F): 单行显示当前高亮候选的译文,空格上屏
// 注意: 不用 @State/@StateObject 等 SwiftUI 宏属性包装器——CLT 环境找不到 SwiftUIMacros 插件,
// 窗口状态(候选条起点/网格行起点)全部由 InputController 持有并以 props 传入。

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
    var onSelect: (Int) -> Void
    var onToggleExpand: () -> Void  // ▾/▴ 展开收起网格

    // 选中胶囊的流动变形(glassEffectID)需要 Namespace;@Namespace 是普通属性包装器,CLT 环境可用
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
                slidingBar
            }
        }
        .fixedSize(horizontal: true, vertical: false) // 防截断:按内容自然宽度撑开
        .padding(9)
    }

    // 横向滑动窗口: 队列式,选中越过边缘时队首滑出、队尾滑入(窗口起点由 InputController 维护,
    // 数字键 1-8 = 窗口内位次;8 与 InputController.perPage 保持一致)
    private var slidingBar: some View {
        let end = min(windowStart + 8, items.count)
        let window = windowStart < end ? Array(items[windowStart..<end]) : []
        return glassFlowContainer {
            HStack(spacing: 3) {
                ForEach(window) { item in
                    CandidateCell(item: item,
                                  number: item.isAI ? "\u{F8FF}" : "\(item.index - windowStart + 1)",
                                  selected: item.index == selectedIndex, ns: glassNS)
                        .onTapGesture { onSelect(item.index) }
                        .transition(Self.slideTransition(forward: slideForward))
                }
                expandChevron("▾")
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: windowStart)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selectedIndex)
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

/// 玻璃形状容器(macOS 26+): 让容器内的选中胶囊与其他玻璃形状融合,配合 glassEffectID
/// 实现在候选之间流动变形(iOS 26 Tab Bar 同款交互);<26 直接渲染
@ViewBuilder fileprivate func glassFlowContainer(@ViewBuilder _ content: () -> some View) -> some View {
    if #available(macOS 26.0, *) {
        GlassEffectContainer(spacing: 4) { content() }
    } else {
        content()
    }
}

private struct CandidateCell: View {
    let item: CandidateItem
    let number: String
    let selected: Bool
    var ns: Namespace.ID?
    var gridCell = false

    var body: some View {
        HStack(spacing: 4) {
            Text(number)
                .font(.system(size: gridCell ? 10 : 11, weight: .semibold))
                .foregroundStyle(item.isAI ? AnyShapeStyle(.cyan) : AnyShapeStyle(.secondary))
                .frame(width: gridCell ? 16 : 9)
                .baselineOffset(-1)
            Text(item.text)
                .font(.system(size: gridCell ? 14 : 16, weight: selected ? .semibold : .regular))
                .foregroundStyle(.primary)
                .fixedSize()
                .lineLimit(1)
        }
        .padding(.horizontal, gridCell ? 6 : 10)
        .padding(.vertical, gridCell ? 4 : 7)
        .frame(minWidth: gridCell ? 62 : 0, alignment: .leading)
        .modifier(LiquidGlassPill(selected: selected, id: item.index, ns: ns))
        .contentShape(Rectangle())
    }
}

/// 选中候选的液态玻璃胶囊(macOS 26+ 系统 glassEffect 控件,同款系统候选窗/工具栏按钮质感;
/// <26 退回白色半透明填充)。数字与词包含在胶囊内,未选中无底色;
/// 在 GlassEffectContainer 内带 ns 时,胶囊随选中变化在候选间流动变形(glassEffectID)。
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

// MARK: - 展开网格(8 列固定 × 上下滑动窗口)

private struct CandidateGridView: View {
    var items: [CandidateItem]
    var selectedIndex: Int
    var rowStart: Int       // 可见行窗口起点(InputController 持有)
    var slideDown: Bool     // 行滑动方向
    var ns: Namespace.ID?   // 选中胶囊流动变形
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
                                CandidateCell(item: item,
                                              number: item.isAI ? "\u{F8FF}" : "\(item.index + 1)",
                                              selected: item.index == selectedIndex, ns: ns, gridCell: true)
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

    static func rowTransition(down: Bool) -> AnyTransition {
        let inEdge: Edge = down ? .bottom : .top
        let outEdge: Edge = down ? .top : .bottom
        return .asymmetric(insertion: .move(edge: inEdge).combined(with: .opacity),
                           removal: .move(edge: outEdge).combined(with: .opacity))
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
    /// isLoading 且 items 为空时显示 FM 占位(光标处预留空间,整句到达后原位替换)。
    /// onToggleExpand: ▾/▴ 鼠标点击展开/收起网格。
    func show(items: [CandidateItem], selectedIndex: Int, windowStart: Int, slideForward: Bool,
              expanded: Bool, rowStart: Int, rowSlideDown: Bool,
              translation: TranslationDisplay?, isLoading: Bool = false,
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
            translation: translation, isLoading: isLoading,
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
