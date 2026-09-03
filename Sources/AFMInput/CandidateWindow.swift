import AppKit
import SwiftUI
import IMECore

// MARK: - 候选条 SwiftUI 视图(参考 macOS 26 候选窗样式)

struct CandidateItem: Identifiable, Equatable {
    var id: Int { index }
    let index: Int      // 全局下标(跨页连续)
    let text: String
    let isAI: Bool      // FM 重排提到首位时显示 ✦
}

struct CandidateBarView: View {
    var items: [CandidateItem]
    var selectedIndex: Int      // 全局下标
    var hasMorePages: Bool
    var onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(items) { item in
                CandidateCell(item: item, selected: item.index == selectedIndex)
                    .onTapGesture { onSelect(item.index) }
            }
            if hasMorePages {
                Text("▸")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 2)
            }
        }
        .fixedSize(horizontal: true, vertical: false) // 防截断:按内容自然宽度撑开
        .padding(9)
    }
}

private struct CandidateCell: View {
    let item: CandidateItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(item.isAI ? "✦" : "\(item.index + 1)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(item.isAI ? AnyShapeStyle(.cyan) : AnyShapeStyle(.secondary))
                .baselineOffset(-1)
            Text(item.text)
                .font(.system(size: 16, weight: selected ? .semibold : .regular))
                .foregroundStyle(.primary)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 9)
                .fill(selected ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(.clear))
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 液态玻璃候选窗(NSPanel + NSGlassEffectView)

/// 非激活 NSPanel,不抢焦点;NSGlassEffectView 提供真·液态玻璃(暗色/亮色自适应);
/// 内容为 SwiftUI 候选条;跟随光标定位。玻璃效果需要 macOS 26+,低版本退化为普通视图。
final class CandidateWindowController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<CandidateBarView>?
    private var onSelect: (Int) -> Void = { _ in }

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
            items: [], selectedIndex: 0, hasMorePages: false,
            onSelect: { [weak self] idx in self?.onSelect(idx) }))
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
    func show(items: [CandidateItem], selectedIndex: Int,
              hasMorePages: Bool, caretRect: NSRect, onSelect: @escaping (Int) -> Void) {
        let panel = ensurePanel()
        self.onSelect = onSelect
        guard let host = hostingView else { return }

        host.rootView = CandidateBarView(
            items: items, selectedIndex: selectedIndex,
            hasMorePages: hasMorePages, onSelect: { [weak self] idx in self?.onSelect(idx) })

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
        DebugLog.log("候选窗显示 size=\(NSStringFromSize(size)) origin=\(NSStringFromPoint(origin)) caret=\(NSStringFromRect(caretRect))")
    }

    func hide() {
        panel?.orderOut(nil)
    }
}
