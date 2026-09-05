import Foundation

/// 用户词频层:用户打字越多,该词权重越高(候选打分乘法加成,词典权重本身不动)。
/// 存储:UserDefaults 字典 [word: count](IME 进程域,与 AFMEnglishMode 同处);
/// 加成 = min(1 + 0.5·log10(1+count), 3.0)——10 次 ×1.5 / 100 次 ×2 / 1000 次 ×2.5,
/// 封顶 ×3 防霸榜;主线程访问(engine 查询与 InputController 上屏都在主线程),保存防抖 2s 合并写。
public final class UserFreq {
    public static let shared = UserFreq()

    private static let storeKey = "AFMUserFreq"
    private static let maxEntries = 5000
    private static let maxWordLen = 50 // 整句/长文本(FM 整句、剪贴板)不进词频

    private let defaults: UserDefaults
    private var counts: [String: Int]
    private var saveScheduled = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.counts = defaults.dictionary(forKey: Self.storeKey) as? [String: Int] ?? [:]
    }

    /// 候选被用户选用(空格/数字/点选/分段转换)时计数一次
    public func record(_ word: String) {
        guard !word.isEmpty, word.count <= Self.maxWordLen else { return }
        counts[word, default: 0] += 1
        if counts.count > Self.maxEntries { trim() }
        scheduleSave()
    }

    /// 打分乘数: 未打过 = ×1.0,打得越多越高,封顶 ×3
    public func boost(_ word: String) -> Double {
        guard let c = counts[word], c > 0 else { return 1.0 }
        return min(1 + 0.5 * log10(Double(c) + 1), 3.0)
    }

    public func count(_ word: String) -> Int { counts[word] ?? 0 }

    /// 超容量时淘汰次数最低的词条
    private func trim() {
        let drop = counts.sorted { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }
            .prefix(counts.count - Self.maxEntries).map(\.key)
        for k in drop { counts.removeValue(forKey: k) }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            self.defaults.set(self.counts, forKey: Self.storeKey)
        }
    }
}
