import Foundation

/// 用户词频 + 用户词库层:
/// - 词频:选用次数越多排序乘法加成越高(封顶 ×3,词典权重本身不动);
/// - 用户词库(kb26):上屏时记录该词命中的拼音键(空格分隔音节),后续同键输入直接命中并处于
///   最高优先档——「打得越多权重越高」的主实现:用过的词立即置顶,次数只在用户词内部决定
///   相对次序(userScore 随次数单调增长)。
/// 存储:UserDefaults 两个字典(word→count / word→拼音键),容量 5000 按次数淘汰,保存防抖 2s。
/// 主线程访问(engine 查询与 InputController 上屏都在主线程)。
public final class UserFreq {
    public static let shared = UserFreq()

    private static let storeKey = "AFMUserFreq"
    private static let pinyinStoreKey = "AFMUserPinyin"
    private static let maxEntries = 5000
    private static let maxWordLen = 50     // 整句/长文本(FM 整句、剪贴板)不进词频

    private let defaults: UserDefaults
    private var counts: [String: Int]
    private var pinyins: [String: String]
    private var saveScheduled = false

    // 派生索引(懒重建): 拼音有序表(前缀二分,缓存音节数组供宽松匹配) + 简拼索引
    private var sortedPins: [(pinyin: String, syls: [String], word: String, count: Int)] = []
    private var initialsIndex: [String: [(word: String, count: Int, pinyin: String)]] = [:]
    private var indexDirty = true

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.counts = defaults.dictionary(forKey: Self.storeKey) as? [String: Int] ?? [:]
        self.pinyins = defaults.dictionary(forKey: Self.pinyinStoreKey) as? [String: String] ?? [:]
    }

    /// 候选被选用(空格/数字/点选/分段转换)时计数一次;pinyin 传该词命中的词典键(空格分隔音节),
    /// 合法时进用户词库(FM 整句等无真实拼音的不收)
    public func record(_ word: String, pinyin: String? = nil) {
        guard !word.isEmpty, word.count <= Self.maxWordLen else { return }
        counts[word, default: 0] += 1
        if let p = pinyin, Self.isValidPinyin(p), word.count <= 12 {
            if pinyins[word] != p {
                pinyins[word] = p
                indexDirty = true
            }
        }
        if counts.count > Self.maxEntries { trim() }
        indexDirty = true // 次数变化影响索引中的 count
        scheduleSave()
    }

    /// 用户词库打分:随使用次数单调增长(「打得越多权重越高」;仅决定用户词之间的相对次序,
    /// 用户词整体已处于最高优先档)
    public func userScore(count: Int) -> Double {
        20_000 + 15_000 * log10(Double(1 + count))
    }

    /// 用户词库命中: 词条拼音与 key 完全一致;partialPrefix 时允许词条拼音以 key 为前缀(尾音节未打全);
    /// 另收简拼(key == 各音节首字母连接)。前缀经二分查找,复杂度 O(log n + 命中数)
    public func hits(key: String, partialPrefix: Bool) -> [(word: String, pinyin: String, count: Int)] {
        if indexDirty { rebuildIndex() }
        var out: [(word: String, pinyin: String, count: Int)] = []
        var lo = 0, hi = sortedPins.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedPins[mid].pinyin < key { lo = mid + 1 } else { hi = mid }
        }
        var i = lo
        while i < sortedPins.count, sortedPins[i].pinyin.hasPrefix(key) {
            let e = sortedPins[i]
            if partialPrefix || e.pinyin == key { out.append((e.word, e.pinyin, e.count)) }
            i += 1
        }
        if let list = initialsIndex[key] {
            for e in list where !out.contains(where: { $0.word == e.word }) {
                out.append((e.word, e.pinyin, e.count))
            }
        }
        return out
    }

    /// 宽松命中(快路径无命中时的兜底): 逐音节前缀匹配——查询的每个音节都只需是对应词条音节的
    /// 前缀,中间音节(mebengz 的 me⊂mei)与缩写音节(zhedm 的 d⊂de、m⊂ma)都能命中;
    /// 候选池是用户自己的词,放宽不引入陌生词
    public func looseHits(key: String, limit: Int = 5) -> [(word: String, pinyin: String, count: Int)] {
        if indexDirty { rebuildIndex() }
        let qs = key.split(separator: " ").map(String.init)
        guard !qs.isEmpty else { return [] }
        var out: [(word: String, pinyin: String, count: Int)] = []
        for e in sortedPins {
            guard qs.count <= e.syls.count else { continue }
            var ok = true
            for (i, q) in qs.enumerated() where e.syls[i].hasPrefix(q) == false {
                ok = false
                break
            }
            if ok {
                out.append((e.word, e.pinyin, e.count))
                if out.count >= limit { break }
            }
        }
        return out
    }

    /// 打分乘数(词频层): 未打过 = ×1.0,打得越多越高,封顶 ×3
    public func boost(_ word: String) -> Double {
        guard let c = counts[word], c > 0 else { return 1.0 }
        return min(1 + 0.5 * log10(Double(c) + 1), 3.0)
    }

    public func count(_ word: String) -> Int { counts[word] ?? 0 }

    public static func isValidPinyin(_ p: String) -> Bool {
        !p.isEmpty && p.count <= 24 && p.allSatisfy { ($0.isLowercase && $0.isASCII) || $0 == " " }
    }

    /// 超容量时淘汰次数最低的词条
    private func trim() {
        let drop = counts.sorted { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }
            .prefix(counts.count - Self.maxEntries).map(\.key)
        for k in drop {
            counts.removeValue(forKey: k)
            pinyins.removeValue(forKey: k)
        }
        indexDirty = true
    }

    private func rebuildIndex() {
        sortedPins = pinyins.compactMap { (word, pin) in
            counts[word].map { (pin, pin.split(separator: " ").map(String.init), word, $0) }
        }.sorted { $0.pinyin < $1.pinyin }
        initialsIndex = [:]
        for e in sortedPins {
            let ini = e.syls.map { String($0.prefix(1)) }.joined()
            initialsIndex[ini, default: []].append((e.word, e.count, e.pinyin))
        }
        indexDirty = false
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            self.defaults.set(self.counts, forKey: Self.storeKey)
            self.defaults.set(self.pinyins, forKey: Self.pinyinStoreKey)
        }
    }
}
