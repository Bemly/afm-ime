import AppKit
import SwiftUI
import IMECore

// MARK: - 候选条 SwiftUI 视图(参考 macOS 26 候选窗样式)
//
// 三种展示态:
//  - 候选条(默认): 恒显前 8 个候选(无滑动窗口),←→ 移动选中,越过第 8 个由控制器直接展开网格;
//    选中态 = 透明液态玻璃水滴(Kyant0 AndroidLiquidGlass LiquidBottomTabs 同款思路):
//    折射 = Metal lens(DropletLens.metal,AGSL lens 逐行移植)作用于幽灵行快照(强调色层),
//    水滴本体 = 玻璃胶囊,按住可拖,松手吸附上屏;按压鼓起/松开回弹/抓取游动走贝塞尔过冲动画
//  - 网格(↓ 展开): 8 列 × ScrollView 滚动(滚轮/滚动条),移回首行(前 8 个)自动收起
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
/// 拖拽双模式(门控 UserPrefs.dropletFixedLens,beginDrag 时快照):
///  - 默认:水滴在条内滑动(钳制在可见 8 个内,bar 不动)——rootView 重建会中断进行中的手势;
///  - 固定透镜(测试):水滴钉在屏幕抓取点(D0 恒定),整条 bar(玻璃+字刚体)随手指平移,
///    拖拽期局部窗口 dragWindowStart 随锚点滑移并用精确词宽补偿面板位置(hop),字在屏幕上冻结。
final class CandidateDropletModel: ObservableObject {
    /// 单例(面板/覆盖层/控制器多视图引用同一份几何与折射输出)
    static let shared = CandidateDropletModel()

    // 布局输入(show 时由控制器更新)
    private(set) var itemCount = 0
    private(set) var barGlassHeight: CGFloat = 44 // 玻璃条高度(点)
    private(set) var selectedIndex = 0
    @Published var items: [CandidateItem] = []    // 幽灵折射层的内容源(overlay 渲染)
    var onDrop: ((Double) -> Void)?               // 松手:连续全局下标 → 吸附上屏
    var onPanelShift: ((CGFloat) -> Void)?        // 固定透镜拖拽:面板(整条 bar)原点平移(控制器执行)

    // 面板几何基准(show/shiftPanel 时由控制器回写;固定透镜拖拽的平移基准)
    private(set) var panelOriginX: CGFloat = 0

    // 几何输入(cell frame 回写)
    @Published var frames: [Int: CGRect] = [:]
    @Published var rowFrame: CGRect = .null       // cells HStack frame(同坐标)

    // 交互态
    @Published var dragFraction: Double? = nil    // 拖拽中的连续全局下标(nil = 非拖拽)
    @Published var press: Double = 0              // 按压进度 0-1
    @Published var velocity: Double = 0           // 平滑拖拽速度(归一,驱动挤压拉伸)
    /// 固定透镜拖拽中的局部窗口起点(barView/幽灵行拖拽期间用它渲染;拖拽结束归零)
    @Published var dragWindowStart = 0
    /// 是否处于固定透镜拖拽中(门控在 beginDrag 时快照,手势内恒定)
    var fixedLensDragging: Bool { dragFraction != nil && fixedLens }
    private var fixedLens = false                 // 门控快照
    private var D0: CGFloat = 0                   // 水滴屏幕 x(抓取时确定,拖拽期间恒定)
    private var P0: CGFloat = 0                   // 抓取时面板原点 x
    private var hop: CGFloat = 0                  // 窗口滑移的面板补偿累计(精确词宽;保证词屏幕冻结)
    private var avgPitch: CGFloat = 60            // 平均格宽(锚点粗定位回退;精确锚点走 frames 扫描)
    private var grabFrames: [Int: CGRect] = [:]   // 抓取时 cell frame 快照(窗口滑移补偿用精确词宽)
    private var pinnedFrame: CGRect?              // 水滴静止 frame(candBar 坐标;拖拽中随面板平移更新)

    // 产出(overlay 直接渲染)
    @Published var blobFrame: CGRect? = nil       // 水滴最终 frame(含缩放/挤压)
    @Published var cellFrame: CGRect? = nil       // 选中格原始 frame(网格态幽灵字对齐用)
    /// 翻译/占位等非候选形态:水滴整体隐藏(网格态保留水滴作选中指示)
    var suppressed = false
    /// 网格态: 水滴贴合选中格(尺寸/定位不同于条态),几何按全量 frame 查找
    var gridMode = false
    /// 网格滚动位置(ScrollPosition 按偏移驱动,绕开 scrollTo 对 Grid 内容的空操作;
    /// CLT 禁 @State,持久宿主放本模型)。
    /// 【必须 @Published】scrollTo 只改这个属性本身,不发布变更 SwiftUI 永远不会重渲染应用它——
    /// 指令会躺到下一次按键的无关重渲染时才被捎带执行(表现=跟随永远慢一拍,再按一下动两排)
    @Published var gridScrollPosition = ScrollPosition()
    /// 网格当前滚动到的顶行(边缘跟随计算用;滚轮自由滚动时不追踪,选中移动时公式自校正)
    var gridTopRow = 0
    /// 网格行距(格高 28 钉死 + Grid 垂直间距 1;滚动偏移与视口高度都按它闭合,单一来源在模型,
    /// 补发滚动时 recompute 也要用)
    let gridRowPitch: CGFloat = 29
    /// 滚动跟随指令的有效期: 窗口内若发现选中格仍在视口外(指令被视图更新竞态吞掉),recompute 里补发
    var gridFollowUntil = Date.distantPast
    /// 网格滚动视口 frame(candBar 坐标;滚动帧间竞态时水滴钳回视口防跳出候选框)
    var gridViewport: CGRect? = nil

    func applyLayout(items: [CandidateItem], barGlassHeight: CGFloat, selectedIndex: Int, expanded: Bool) {
        self.items = items
        self.itemCount = items.count
        self.barGlassHeight = barGlassHeight
        self.selectedIndex = selectedIndex
        gridMode = expanded
        recompute()
    }

    func setSelectedIndex(_ idx: Int) {
        selectedIndex = idx
        recompute()
    }

    /// 面板几何基准回写(show/shiftPanel 时由控制器调用;固定透镜拖拽的平移以 panelOriginX 为基准)
    func applyPanelGeometry(originX: CGFloat) {
        panelOriginX = originX
    }

    func reset() {
        dragFraction = nil
        press = 0
        velocity = 0
        dragWindowStart = 0
        pinnedFrame = nil
        recompute()
    }

    func noteCellFrame(_ index: Int, _ frame: CGRect) {
        guard frames[index] != frame else { return } // 去重:onGeometryChange 重渲染时会重发相同值,
        frames[index] = frame                        // 不设防会形成 上报→@Published→重渲染→再上报 死循环
        recompute()
    }

    func noteRowFrame(_ frame: CGRect) {
        guard rowFrame != frame else { return }
        rowFrame = frame
    }

    // MARK: 交互

    func beginDrag(atX x: CGFloat, fallback: Int) {
        press = 1
        velocity = 0
        fixedLens = UserPrefs.dropletFixedLens // 门控快照:手势内恒定,设置改动下次拖拽生效
        dragFraction = fraction(at: x) ?? Double(fallback)
        let fs = windowIndices.compactMap { i in frames[i].map { "\(i):x\(Int($0.minX))w\(Int($0.width))" } }
        DebugLog.log("水滴 beginDrag x=\(String(format: "%.1f", x)) → frac=\(String(format: "%.2f", dragFraction ?? -1)) fallback=\(fallback) n=\(itemCount) 固定透镜=\(fixedLens) [\(fs.joined(separator: " "))]")
        if fixedLens {
            // 水滴钉在屏幕抓取点(D0 恒定),整条 bar 等着从它下面滑过去
            P0 = panelOriginX
            hop = 0
            dragWindowStart = 0
            avgPitch = max(24, rowFrame.width / CGFloat(max(1, min(8, itemCount))))
            grabFrames = frames
            if let cell = interpolatedFrame(at: dragFraction ?? 0) {
                let restH = min(barGlassHeight * 0.875, barGlassHeight - 2)
                let restW = cell.width + 12
                pinnedFrame = CGRect(x: cell.midX - restW / 2, y: cell.midY - restH / 2,
                                     width: restW, height: restH)
            }
            D0 = P0 + (pinnedFrame?.midX ?? x) // 水滴屏幕 x(此后恒定;仅相对量参与运算,基准误差抵消)
            updateBlob(P: P0)
            return
        }
        recompute()
    }

    /// 拖拽中: 直接把指针当前位置重映射为连续 fraction(beginDrag 同款 fraction(at:))。
    /// 【不能用增量累加】手势回调给的是相对起点的累计位移(location-startLocation),
    /// 若当增量逐事件加到 base 上,fraction 以事件数二次方暴涨——几百 ms 内钳到窗口末位,
    /// 表现即「按住还没出第一个词水滴就飞到最后一个候选」(kb10 实测日志钉死)。
    func drag(toX x: CGFloat) {
        guard let base = dragFraction else { return }
        let target = fraction(at: x) ?? base
        let hi = Double(max(0, min(7, itemCount - 1))) // 条恒显前 8 个,钳制在内
        let clamped = max(0.0, min(hi, target))
        let inst = (clamped - base) * 3.0
        velocity = velocity * 0.65 + max(-1, min(1, inst)) * 0.35
        DebugLog.log("水滴 drag toX=\(String(format: "%.1f", x)) base=\(String(format: "%.2f", base)) → \(String(format: "%.2f", clamped)) n=\(itemCount)")
        dragFraction = clamped
        recompute()
    }

    /// 固定透镜拖拽: 面板(玻璃条+字刚体)平移 P = P0 + dx + hop。
    /// hop = 窗口滑移补偿(精确词宽): 锚点词滑到窗口边缘时窗口平移一词宽,字在屏幕上冻结不跳。
    /// 水滴屏幕位置恒定 → 其条内位置随平移反向变化 → 不同候选从水滴下经过。
    /// dx 为手势累计位移(直接代入 P,绝不当增量二次累加——同 drag(toX:) 的 kb10 教训)。
    func drag(by dx: CGFloat) {
        guard dragFraction != nil else { return }
        let prev = dragFraction!
        var P = P0 + dx + hop
        var ws = dragWindowStart
        func anchorAt(_ P: CGFloat, _ ws: Int) -> Double {
            let drop = D0 - P // 水滴 candBar x(面板平移的负向)
            for i in ws..<min(ws + 8, itemCount) {
                if let fr = frames[i], drop >= fr.minX, drop < fr.maxX {
                    return Double(i) + min(1, max(0, (drop - fr.minX) / max(fr.width, 1)))
                }
            }
            return Double(ws) + (drop - 9) / max(avgPitch, 1) // 帧未回写/越端: 平均格宽回退
        }
        var a = anchorAt(P, ws)
        for _ in 0..<3 {
            if a > Double(ws + 6), ws + 8 < itemCount {
                hop += grabFrames[ws]?.width ?? avgPitch // 左缘词退出 → 面板回弹该词宽(字冻结)
                ws += 1
                P = P0 + dx + hop
                a = anchorAt(P, ws)
            } else if a < Double(ws + 1), ws > 0 {
                ws -= 1
                hop -= grabFrames[ws]?.width ?? avgPitch // 右缘进入 → 面板前进该词宽
                P = P0 + dx + hop
                a = anchorAt(P, ws)
            } else { break }
        }
        // 候选范围钳制: 水滴扫到首/尾候选即停
        if a < 0 { P += (0 - a) * avgPitch; a = 0 }
        if a > Double(itemCount - 1) { P -= (a - Double(itemCount - 1)) * avgPitch; a = Double(itemCount - 1) }
        let inst = (a - prev) * 3.0
        velocity = velocity * 0.65 + max(-1, min(1, inst)) * 0.35
        DebugLog.log("水滴固定透镜 drag dx=\(String(format: "%.1f", dx)) P=\(String(format: "%.1f", P)) ws=\(ws) hop=\(String(format: "%.1f", hop)) → frac=\(String(format: "%.2f", a))")
        dragFraction = a
        dragWindowStart = ws
        updateBlob(P: P)
        onPanelShift?(P)
    }

    func endDrag() {
        var f = dragFraction ?? Double(selectedIndex)
        if fixedLens {
            // 吸附: 水滴正下的词(当前渲染几何精确)
            f = dragFraction ?? Double(selectedIndex)
            if let pinned = pinnedFrame {
                for i in dragWindowStart..<min(dragWindowStart + 8, itemCount) {
                    if let fr = frames[i], pinned.midX >= fr.minX, pinned.midX < fr.maxX { f = Double(i); break }
                }
            }
        }
        press = 0
        velocity = 0
        dragFraction = nil
        dragWindowStart = 0
        pinnedFrame = nil
        recompute()
        onDrop?(f)
    }

    // MARK: 几何与渲染

    /// 条=恒显前 8 个;网格=全部(水滴按选中格定位,拖拽仅存在于条态)
    private var windowIndices: Range<Int> {
        gridMode ? 0..<max(0, itemCount) : 0..<min(8, max(0, itemCount))
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

    /// 固定透镜拖拽: 水滴 blob(candBar 坐标)= 屏幕恒定点 D0 在面板坐标系中的投影,仅按压缩放 + 速度挤压
    private func updateBlob(P: CGFloat) {
        guard let pinned = pinnedFrame else { return }
        let rest = CGRect(x: D0 - P - pinned.width / 2, y: pinned.minY,
                          width: pinned.width, height: pinned.height)
        let pressScale = 1 + 0.35 * press
        let vv = max(-1, min(1, velocity))
        let sx = pressScale / (1 - max(-0.2, min(0.2, vv * 0.075)))
        let sy = pressScale * (1 - max(-0.2, min(0.2, vv * 0.025)))
        blobFrame = rest.scaledAboutCenter(sx: sx, sy: sy)
    }

    /// 重算水滴几何(折射由 overlay 的 layerEffect 直接在幽灵层上做,模型只管几何)
    func recompute() {
        if fixedLensDragging { return } // 固定透镜拖拽中: 水滴几何由 drag(by:)/updateBlob 维护
        // 网格态直取选中格 frame!interpolatedFrame 的 minX 排序是条态单行逻辑(单行里 minX 序=下标序),
        // 二维网格下 keys.last 是「末列格」(99 候选时=下标 95,倒数第二行最后一列),
        // f ≥ lastKey 的选中会全部错位吸到末列格——即「到不了最后一行/锁死在倒数第二行最后一列/水滴叠在别的候选上」
        let target: CGRect? = gridMode ? frames[selectedIndex]
                                       : interpolatedFrame(at: dragFraction ?? Double(selectedIndex))
        guard !suppressed, var cell = target else {
            if blobFrame != nil {
                DebugLog.log("水滴几何 → 隐藏 suppressed=\(suppressed) frac=\(dragFraction.map { String(format: "%.2f", $0) } ?? "nil")")
            }
            blobFrame = nil
            cellFrame = nil
            return
        }
        // 网格态: 滚动跟随存在帧间竞态(选中格新 frame 尚未随滚动重报,旧值可能在视口外),
        // 把水滴钳回滚动视口,瞬态也不出候选框;
        // 若在跟随有效期内仍出视口 = 滚动指令被视图更新竞态吞掉 → 立即补发(自愈闭环)
        if gridMode, let vp = gridViewport, vp.width > 0, cell.height > 0 {
            let clampedY = min(max(cell.origin.y, vp.minY), vp.maxY - cell.height)
            if clampedY != cell.origin.y {
                if Date() < gridFollowUntil {
                    let y = CGFloat(gridTopRow) * gridRowPitch
                    DebugLog.log("水滴钳回+补发滚动 y=\(Int(y)) (原 \(String(format: "%.1f", cell.origin.y)))")
                    gridScrollPosition.scrollTo(point: CGPoint(x: 0, y: y))
                }
                cell.origin.y = clampedY
            }
        }
        // 静止尺寸: 条=高 ≈0.875×玻璃条(Kyant0 水滴 56/条 64),宽 = cell + 6;
        // 网格=格四周再放一圈(字不贴框)
        let restH = gridMode ? min(cell.height + 8, barGlassHeight - 2)
                             : min(barGlassHeight * 0.875, barGlassHeight - 2)
        let restW = cell.width + 12
        let rest = CGRect(x: cell.midX - restW / 2, y: cell.midY - restH / 2, width: restW, height: restH)
        // 按压放大 1.35×(Kyant0 pressedScale 78/56)+ 速度挤压拉伸(layerBlock 同款公式)
        let pressScale = 1 + 0.35 * press
        let v = max(-1, min(1, velocity))
        let sx = pressScale / (1 - max(-0.2, min(0.2, v * 0.075)))
        let sy = pressScale * (1 - max(-0.2, min(0.2, v * 0.025)))
        blobFrame = rest.scaledAboutCenter(sx: sx, sy: sy)
        cellFrame = cell
        if dragFraction != nil || press > 0 { // 交互期几何(静止布局期 8 个 cell 回写会刷屏,不记)
            DebugLog.log("水滴几何 frac=\(String(format: "%.2f", dragFraction ?? Double(selectedIndex))) sel=\(selectedIndex) cell=\(NSStringFromRect(cell)) blob=\(NSStringFromRect(blobFrame!))")
        }
    }
}

private extension CGRect {
    func scaledAboutCenter(sx: CGFloat, sy: CGFloat) -> CGRect {
        CGRect(x: midX - width * sx / 2, y: midY - height * sy / 2, width: width * sx, height: height * sy)
    }
}

struct CandidateBarView: View {
    var items: [CandidateItem]      // 全量候选(条恒显前 8 个;网格滚动全量)
    var selectedIndex: Int
    var expanded: Bool              // ↓ 展开的滚动网格态
    var translation: TranslationDisplay?
    var isLoading: Bool             // 无词典候选时占位,等 FM 整句
    @ObservedObject var droplet: CandidateDropletModel
    var onSelect: (Int) -> Void
    var onToggleExpand: () -> Void  // ▾/▴ 展开收起网格

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
                CandidateGridView(items: items, selectedIndex: selectedIndex, droplet: droplet,
                                  onSelect: onSelect, onCollapse: onToggleExpand)
            } else {
                barView
            }
        }
        .fixedSize(horizontal: true, vertical: false) // 防截断:按内容自然宽度撑开
        .padding(9)
        .coordinateSpace(name: "candBar") // 坐标基准 = 玻璃条内容矩形(cell/行/水滴 frame 全在此空间)
    }

    // MARK: 候选条(恒显前 8 个;水滴渲染在面板层 DropletOverlayView,这里只管内容与手势)
    // 固定透镜拖拽中改用拖拽局部窗口 dragWindowStart(窗口滑移由 drag(by:) 驱动),编号=窗口内位次

    private var barView: some View {
        let ws = droplet.fixedLensDragging ? droplet.dragWindowStart : 0
        let end = min(ws + 8, items.count)
        let window = ws < end ? Array(items[ws..<end]) : Array(items.prefix(8))
        return HStack(spacing: 3) {
            ForEach(window) { item in
                CandidateCell(item: item,
                              number: item.isAI ? "\u{F8FF}" : "\(item.index - ws + 1)",
                              active: item.index == selectedIndex)
                    .onTapGesture { onSelect(item.index) }
                    .modifier(FrameReporter(index: item.index, model: droplet))
            }
            expandChevron("▾")
        }
        .modifier(RowFrameReporter(model: droplet))
        .contentShape(Rectangle())
        .gesture(dragGesture)
    }

    /// 按住即抓起水滴(跳到按压处的候选),左右拖连续跟手;
    /// 松手吸附候选并上屏(轻点 = 位移 0 的拖拽,与点选一致)。
    /// 坐标空间 = candBar(frames 全在此空间);固定透镜开时走 drag(by:)(面板平移),否则 drag(toX:)(水滴滑动)。
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("candBar"))
            .onChanged { v in
                if droplet.dragFraction == nil {
                    droplet.beginDrag(atX: v.startLocation.x, fallback: selectedIndex)
                } else if droplet.fixedLensDragging {
                    droplet.drag(by: v.location.x - v.startLocation.x)
                } else {
                    droplet.drag(toX: v.location.x)
                }
            }
            .onEnded { _ in droplet.endDrag() }
    }

    /// 幽灵行快照内容(强调色样式,与正常行逐像素同布局;ImageRenderer 离屏渲染用)。
    /// windowStart: 固定透镜拖拽中的局部窗口起点(须与 barView 同窗,折射内容才逐像素对得上)
    static func ghostSnapshotRow(items: [CandidateItem], windowStart: Int = 0) -> some View {
        let end = min(windowStart + 8, items.count)
        return HStack(spacing: 3) {
            ForEach(windowStart < end ? Array(items[windowStart..<end]) : []) { item in
                CandidateCell(item: item,
                              number: item.isAI ? "\u{F8FF}" : "\(item.index - windowStart + 1)",
                              active: true, ghost: true)
            }
        }
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
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named("candBar")) } action: { _, new in
            model.noteCellFrame(index, new) // 写 @Published 触发水滴重算(布局本身不变,无循环)
        }
    }
}

/// 行 frame 回写(CI 折射的坐标映射基准)
struct RowFrameReporter: ViewModifier {
    let model: CandidateDropletModel

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named("candBar")) } action: { _, new in
            model.noteRowFrame(new)
        }
    }
}

private struct CandidateCell: View {
    let item: CandidateItem
    let number: String
    let active: Bool          // 选中(词加粗)
    var ghost = false         // 幽灵快照样式(强调色,仅水滴折射内可见)
    var gridCell = false

    // 字号: 网格态钉死 14(行距 28/29 几何闭合不能动),条态跟随设置(13-22,默认 16)
    private var textFontSize: Int { gridCell ? 14 : UserPrefs.candidateFontSize }

    var body: some View {
        HStack(spacing: 4) {
            Text(number)
                .font(.system(size: gridCell ? 10 : CGFloat(max(10, textFontSize - 5)), weight: .semibold))
                .foregroundStyle(ghost
                    ? AnyShapeStyle(.cyan)
                    : (item.isAI ? AnyShapeStyle(.cyan) : AnyShapeStyle(.secondary)))
                .frame(width: gridCell ? 16 : 9)
                .baselineOffset(-1)
            Text(item.text)
                .font(.system(size: CGFloat(textFontSize), weight: (active || ghost) ? .semibold : .regular))
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

    /// 按压鼓起/松开回弹的过冲贝塞尔(材质反弹 cubic-bezier(0.3, 0.2, 0.2, 1.4),y1>1 过冲)。
    /// 挂在 press 变化上:抓取瞬间 press 0→1 与位置跳变同事务 → 鼓起与「游到按压处候选」一并走此曲线;
    /// 拖拽跟手期 press 恒为 1 不触发 → 位置保持 1:1 直跟不脱手。
    private static let pressCurve = Animation.timingCurve(0.3, 0.2, 0.2, 1.4, duration: 0.32)
    /// 非拖拽期的选中移动(←→/FM 重排): 条态过冲游动;网格态短滑无过冲(过冲会冲出滚动视口)
    private static let slideCurve = Animation.timingCurve(0.3, 0.2, 0.2, 1.4, duration: 0.28)
    private static let gridSlideCurve = Animation.easeOut(duration: 0.18)

    var body: some View {
        let _ = { // 交互期实际绘制值(渲染层真值);打字刷新期 body 高频重估,静默防刷屏
            if model.dragFraction != nil || model.press > 0 {
                DebugLog.log("水滴渲染 blobFrame=\(model.blobFrame.map { NSStringFromRect($0) } ?? "nil")")
            }
        }()
        ZStack(alignment: .topLeading) {
            if let f = model.blobFrame {
                blobGlass(f)
                if model.gridMode {
                    gridGhostCell() // 玻璃磨砂会糊掉底下的格内容,水滴上层重绘选中格(强调色)
                } else {
                    ghostRefracted(f)
                }
                blobDressing(f)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .offset(x: marginH, y: marginV) // 宿主覆盖全面板,内容坐标为玻璃条内坐标
        .allowsHitTesting(false)
        .animation(Self.pressCurve, value: model.press)
        // 位置动画: 条态过冲游动;网格态短滑(拖拽跟手中为 nil 直跟)
        .animation(model.dragFraction == nil ? (model.gridMode ? Self.gridSlideCurve : Self.slideCurve) : nil,
                   value: model.blobFrame?.origin)
    }

    /// 玻璃水滴本体(26+ 系统玻璃/<26 白色半透明)+ 投影
    @ViewBuilder private func blobGlass(_ f: CGRect) -> some View {
        Color.clear
            .glassEffect(.regular.interactive(), in: Capsule())
            .frame(width: f.width, height: f.height)
        .shadow(color: .black.opacity(0.22 * model.press), radius: 4 + 3 * model.press, y: 2)
        .offset(x: f.minX, y: f.minY)
    }

    /// 折射的幽灵层: 幽灵行(强调色)经 Metal lens 掩膜+折射,仅水滴内可见
    /// (构建期 default.metallib 缺失 → maskShader nil → 无此层,水滴退化为纯玻璃)
    @ViewBuilder private func ghostRefracted(_ f: CGRect) -> some View {
        if model.rowFrame.width > 0,
           let shader = DropletLens.maskShader(
            rect: CGRect(x: f.minX - model.rowFrame.minX, y: f.minY - model.rowFrame.minY,
                         width: f.width, height: f.height),
            refraction: (h: 10 * model.press, amount: -14 * model.press),
            layerSize: model.rowFrame.size) {
            CandidateBarView.ghostSnapshotRow(items: model.items,
                                              windowStart: model.fixedLensDragging ? model.dragWindowStart : 0)
                .layerEffect(shader, maxSampleOffset: DropletLens.maxSampleOffset)
                .offset(x: model.rowFrame.minX, y: model.rowFrame.minY)
                .allowsHitTesting(false)
        }
    }

    /// 网格态幽灵字: 选中格内容以强调色重绘在水滴上层,frame 对齐原格(同条态幽灵行,无折射)。
    /// 编号与格子一致用行内 1-8(全局序号键盘敲不出来,没意义);
    /// 必须带 gridCell: true 用网格样式——条态样式(字大/边距宽)塞进网格框会整体错位出框
    @ViewBuilder private func gridGhostCell() -> some View {
        if let cf = model.cellFrame,
           let item = model.items.first(where: { $0.index == model.selectedIndex }) {
            CandidateCell(item: item,
                          number: item.isAI ? "\u{F8FF}" : "\(model.selectedIndex % 8 + 1)",
                          active: true, ghost: true, gridCell: true)
                .frame(width: cf.width, height: cf.height)
                .offset(x: cf.minX, y: cf.minY)
                .allowsHitTesting(false)
        }
    }

    /// 表面处理: 容器色 + 上缘高光(Kyant0 onDrawSurface/Highlight,强度随按压)
    @ViewBuilder private func blobDressing(_ f: CGRect) -> some View {
        Capsule()
            .fill(.white.opacity(0.08 * model.press))
            .overlay {
                Capsule().stroke(
                    LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
                    .opacity(0.3 + 0.5 * model.press)
            }
            .frame(width: f.width, height: f.height)
            .offset(x: f.minX, y: f.minY)
    }
}

// MARK: - 展开网格(8 列 × ScrollView 滚动: 滚轮/滚动条,选中行越界自动滚入)

private struct CandidateGridView: View {
    var items: [CandidateItem]
    var selectedIndex: Int
    @ObservedObject var droplet: CandidateDropletModel // 格 frame 回写(水滴在网格态作选中指示,随 ←→↑↓ 游动)
    var onSelect: (Int) -> Void
    var onCollapse: () -> Void
    private let cols = 8        // 8 列固定窗口(与 InputController.gridColumns 一致)
    private let visibleRows = 4 // 可见行数(与 InputController.gridVisibleRows 一致)
    private var rowPitch: CGFloat { droplet.gridRowPitch } // 行距单一来源在模型(补发滚动也要用)

    var body: some View {
        let allRows = stride(from: 0, to: items.count, by: cols)
            .map { start in Array(items[start..<min(start + cols, items.count)]) }
        VStack(spacing: 5) {
            if !allRows.isEmpty {
                scrollGrid(allRows)
            }
            HStack(spacing: 8) {
                Text("↑↓←→ 移动 · 滚轮滚动 · 数字选词 · 点击上屏")
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

    /// 真滚动容器: 鼠标滚轮与滚动条直接控制;←→↑↓ 移动选中时按行距绝对偏移滚到目标行。
    /// (ScrollViewReader.scrollTo 对 Grid 内容是空操作——实测日志证明 onChange 有触发但不滚动,
    ///  故用 ScrollPosition 按偏移量驱动,与视图 id 无关)
    private func scrollGrid(_ allRows: [[CandidateItem]]) -> some View {
        ScrollView(.vertical) {
            Grid(alignment: .leading, horizontalSpacing: 2, verticalSpacing: 1) {
                ForEach(allRows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(allRows[r]) { item in
                            gridCell(item)
                                .onTapGesture { onSelect(item.index) }
                                .modifier(FrameReporter(index: item.index, model: droplet))
                        }
                    }
                    .id(r)
                }
            }
            .padding(1)
        }
        .scrollPosition($droplet.gridScrollPosition)
        .scrollIndicators(.visible)
        .frame(height: CGFloat(min(allRows.count, visibleRows)) * rowPitch - 1)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("candBar")) } action: { _, new in
            if droplet.gridViewport != new { droplet.gridViewport = new } // 同上,去重防死循环
        }
        .onChange(of: selectedIndex) { _, tgt in
            scrollToSelectedRow(tgt)
        }
        .onAppear {
            scrollToSelectedRow(selectedIndex)
        }
    }

    /// 边缘跟随: 选中行在可视窗口内不滚动;↓ 越出底行 → 贴底(只出新的一行),↑ 越出顶行 → 贴顶(只出旧的一行)
    private func scrollToSelectedRow(_ tgt: Int) {
        let row = tgt / cols
        var top = droplet.gridTopRow
        if row < top {
            top = row
        } else if row >= top + visibleRows {
            top = row - visibleRows + 1
        }
        droplet.gridTopRow = top
        let y = CGFloat(top) * rowPitch
        DebugLog.log("网格滚动跟随 top=\(top) y=\(Int(y))")
        if let f0 = droplet.frames[0], let f1 = droplet.frames[cols] {
            DebugLog.log("网格实测行距 \(String(format: "%.1f", f1.minY - f0.minY)) (预算 \(Int(rowPitch)))") // 现场校验钉死高度是否生效
        }
        withAnimation(.spring(response: 0.22, dampingFraction: 1)) { // 跟随带滑动动画,不闪现
            droplet.gridScrollPosition.scrollTo(point: CGPoint(x: 0, y: y))
        }
    }

    private func gridCell(_ item: CandidateItem) -> some View {
        let selRow = selectedIndex / cols
        let inSelRow = item.index / cols == selRow // 仅水滴所在行显示行内编号 1-8
        return HStack(spacing: 4) {
            Text(item.isAI ? "\u{F8FF}" : (inSelRow ? "\(item.index - selRow * cols + 1)" : ""))
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
        // 高度必须固定: 行距/视口高/滚动偏移全按 rowPitch 闭合估算,idealHeight 不钉死会导致
        // 实际行距偏大 → 滚到底够不着最后一行、视口底部裁出半行(表现为候选词重叠)
        .frame(minWidth: 62, minHeight: 28, maxHeight: 28, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - 液态玻璃候选窗(NSPanel)

/// 结构(为水滴"胀出条外"预留边距): 面板 = 容器(透明,含边距)
///   ├─ 玻璃视窗(NSGlassEffectView,26+;即候选条本体矩形) / <26 直接放宿主
///   │    └─ 候选条宿主(SwiftUI: 前 8 个候选 + 手势;网格态 = 滚动网格)
///   └─ 水滴覆盖宿主(全面板,SwiftUI 玻璃胶囊 + Metal 折射幽灵层;hitTest 全透传)
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

    /// 候选窗玻璃条 frame 变化回调(nil = 隐藏);伴随面板据此重新浮动定位
    var onFrameChange: ((NSRect?) -> Void)?
    var currentFrame: NSRect { panel?.frame ?? NSRect.null }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 固定透镜拖拽:整条 bar(面板)刚体平移(x 钳在屏幕内;y 不变)。
    /// 面板几何变了,水滴模型基准同步(词屏幕冻结的补偿依赖它)。
    func shiftPanel(toOriginX x: CGFloat) {
        guard let panel else { return }
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let cx = max(visible.minX + 4, min(visible.maxX - panel.frame.width - 4, x))
        panel.setFrameOrigin(NSPoint(x: cx, y: panel.frame.origin.y))
        InputController.dropletModel.applyPanelGeometry(originX: panel.frame.origin.x)
        let barFrame = panel.frame.offsetBy(dx: Self.marginH, dy: Self.marginV)
        onFrameChange?(NSRect(origin: barFrame.origin, size: barFrame.size))
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
        p.becomesKeyOnlyIfNeeded = true

        let barRoot = CandidateBarView(
            items: [], selectedIndex: 0,
            expanded: false, translation: nil, isLoading: false,
            droplet: CandidateDropletModel.shared,
            onSelect: { [weak self] idx in self?.onSelect(idx) },
            onToggleExpand: { [weak self] in self?.onToggleExpand() })
        let barHost = NSHostingView(rootView: barRoot)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        container.wantsLayer = true
        let glass = NSGlassEffectView()
        glass.cornerRadius = 22
        glass.effectIsInteractive = true
        glass.contentView = barHost
        container.addSubview(glass)
        glassView = glass
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
    func show(items: [CandidateItem], selectedIndex: Int,
              expanded: Bool, translation: TranslationDisplay?, isLoading: Bool = false,
              droplet: CandidateDropletModel,
              caretRect: NSRect, onSelect: @escaping (Int) -> Void,
              onToggleExpand: @escaping () -> Void = {}) {
        let panel = ensurePanel()
        self.onSelect = onSelect
        self.onToggleExpand = onToggleExpand
        guard let host = barHosting, let container = containerView else { return }

        host.rootView = CandidateBarView(
            items: items, selectedIndex: selectedIndex,
            expanded: expanded, translation: translation, isLoading: isLoading, droplet: droplet,
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
        DebugLog.log("水滴布局 panel=\(NSStringFromRect(panel.frame)) container=\(NSStringFromRect(container.frame)) glass=\(NSStringFromRect((glassView ?? barHosting)?.frame ?? .null)) overlay=\(NSStringFromRect(overlayHosting?.frame ?? .null)) row=\(NSStringFromRect(droplet.rowFrame))")

        // 水滴布局输入(折射由 overlay 的 Metal layerEffect 直接做;网格态水滴作选中指示)
        droplet.suppressed = translation != nil || isLoading
        droplet.applyLayout(items: items,
                            barGlassHeight: barSize.height, selectedIndex: selectedIndex,
                            expanded: expanded)

        let barFrame = panel.frame.offsetBy(dx: Self.marginH, dy: Self.marginV)
        onFrameChange?(NSRect(origin: barFrame.origin, size: barSize))
        DebugLog.log("候选窗显示 bar=\(NSStringFromSize(barSize)) origin=\(NSStringFromPoint(barOrigin)) caret=\(NSStringFromRect(caretRect)) 网格=\(expanded)")

        // 固定透镜拖拽的面板几何基准(拖拽平移以此为 P0)
        droplet.applyPanelGeometry(originX: panel.frame.origin.x)
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
