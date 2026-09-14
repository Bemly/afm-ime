import Foundation

/// 用户词频 + 用户词库层:
/// - 词频:选用次数越多排序乘法加成越高(封顶 ×3,词典权重本身不动);
/// - 用户词库(kb26):上屏时记录该词命中的拼音键(空格分隔音节),后续同键输入直接命中并处于
///   最高优先档——「打得越多权重越高」的主实现:用过的词立即置顶,次数只在用户词内部决定
///   相对次序(userScore 随次数单调增长)。
/// 存储:UserDefaults 两个字典(word→count / word→拼音键),容量 5000 按次数淘汰,保存防抖 2s。
/// 内置词种子(kb40):bundle Resources 的 builtin-user-words.json 按其 version 门控在首次运行时
/// 合入本地库(只补缺失词,已有词取较大次数、拼音仅缺省才补),文件更新 version 后自动补种;
/// 删除过的词经墓碑表(AFMUserWordsDeleted)挡住,不随版本升级复活。
/// 跨进程:设置中心进程会直接改写 defaults(导入/删除/清空),经 Darwin 通知广播(CFNotificationCenter,
/// libnotify 的 notify_* 在 Swift 无模块可 import),本类收到后丢弃防抖窗口内的未落盘改动并重读——
/// 外部改动优先于内存副本(防删掉的词被引擎下次保存复活)。
/// 主线程访问(engine 查询与 InputController 上屏都在主线程;Darwin 中心回调走注册线程的 run loop,
/// 注册发生在主线程 init)。
public final class UserFreq {
    public static let shared = UserFreq()

    private static let storeKey = "AFMUserFreq"
    private static let pinyinStoreKey = "AFMUserPinyin"
    private static let maxEntries = 5000
    private static let maxWordLen = 50     // 整句/长文本(FM 整句、剪贴板)不进词频
    private static let seededVersionKey = "AFMBuiltinUserWordsSeeded"
    private static let deletedSeedsKey = "AFMUserWordsDeleted"

    /// 设置中心 → 引擎 的跨进程变更广播名(Darwin 通知)
    public static let externalChangeNotify = "moe.bemly.inputmethod.AfmIME.userdict.changed"

    private let defaults: UserDefaults
    private var counts: [String: Int]
    private var pinyins: [String: String]
    private var saveScheduled = false
    private var observing = false

    // 派生索引(懒重建): 拼音有序表(前缀二分,缓存音节数组供宽松匹配) + 简拼索引
    private var sortedPins: [(pinyin: String, syls: [String], word: String, count: Int)] = []
    private var initialsIndex: [String: [(word: String, count: Int, pinyin: String)]] = [:]
    private var indexDirty = true

    /// builtinWordsURL 仅测试用(nil = 从 Bundle.main Resources 找 builtin-user-words.json;
    /// 设置中心 helper bundle 也放了同款资源,先启动的是谁都完成补种)
    public init(defaults: UserDefaults = .standard, builtinWordsURL: URL? = nil) {
        self.defaults = defaults
        self.counts = defaults.dictionary(forKey: Self.storeKey) as? [String: Int] ?? [:]
        self.pinyins = defaults.dictionary(forKey: Self.pinyinStoreKey) as? [String: String] ?? [:]
        // 迁移: 清洗历史脏键(缩写键「的=d」/半截尾音节「好下=hao x」——教训是逐音节 ≥2 字母才收)
        let bad = pinyins.filter { !Self.isValidPinyin($0.value) }.map(\.key)
        if !bad.isEmpty {
            for k in bad { pinyins.removeValue(forKey: k) }
            defaults.set(pinyins, forKey: Self.pinyinStoreKey)
        }
        observeExternalChanges()
        seedBuiltinWordsIfNeeded(url: builtinWordsURL ?? Bundle.main.url(forResource: "builtin-user-words", withExtension: "json"))
    }

    deinit {
        if observing {
            CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
        }
    }

    /// 设置中心侧改写 defaults 后调用(导入/删除/清空统一出口),引擎重读防复活
    public static func postExternalChange() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(externalChangeNotify as CFString),
                                             nil, nil, true)
    }

    private func observeExternalChanges() {
        // C 函数指针闭包不能捕获上下文,实例经 observer 指针回传(deinit 时成对移除)
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        Unmanaged.passUnretained(self).toOpaque(),
                                        { _, observer, _, _, _ in
                                            guard let observer else { return }
                                            Unmanaged<UserFreq>.fromOpaque(observer).takeUnretainedValue().reloadFromDefaults()
                                        },
                                        Self.externalChangeNotify as CFString, nil, .deliverImmediately)
        observing = true
    }

    /// 外部(设置中心)改写了 defaults:重读并取消待落盘的防抖保存——内存副本里的未落盘改动
    /// 会被丢弃(最多丢 2s 防抖窗口内的计数,外部改动优先)
    private func reloadFromDefaults() {
        counts = defaults.dictionary(forKey: Self.storeKey) as? [String: Int] ?? [:]
        pinyins = defaults.dictionary(forKey: Self.pinyinStoreKey) as? [String: String] ?? [:]
        saveScheduled = false
        indexDirty = true
        DebugLog.log("用户词: 收到外部变更,重读 defaults(\(counts.count) 条)")
    }

    /// 删除墓碑:设置中心删除/清空词时记录,补种时跳过——被用户删掉的词不随种子版本升级复活。
    /// 对非内置词记墓碑无害(墓碑只被补种读取);defaults 参数化,设置中心写的是 IME suite 域
    public static func tombstone(words: [String], defaults: UserDefaults) {
        guard !words.isEmpty else { return }
        var set = Set(defaults.stringArray(forKey: deletedSeedsKey) ?? [])
        set.formUnion(words)
        defaults.set(Array(set), forKey: deletedSeedsKey)
    }

    /// 导入属显式行为,覆盖墓碑(文件里带回曾删的词 = 用户改主意)
    public static func untombstone(words: [String], defaults: UserDefaults) {
        guard !words.isEmpty, let old = defaults.stringArray(forKey: deletedSeedsKey), !old.isEmpty else { return }
        defaults.set(Array(Set(old).subtracting(words)), forKey: deletedSeedsKey)
    }

    /// 内置词种子:文件 version > 已种版本才合入;只补缺失词(已有词保本机次数,取文件与本地
    /// 较大者;拼音仅本地缺省才补),墓碑词(用户删过)一律跳过;文件缺失/损坏不写标记,下次启动重试
    private func seedBuiltinWordsIfNeeded(url: URL?) {
        guard let url, let data = try? Data(contentsOf: url),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = doc["version"] as? Int,
              let items = doc["words"] as? [[String: Any]] else {
            DebugLog.log("用户词种子: bundle 无 builtin-user-words.json 或格式不对,跳过")
            return
        }
        guard defaults.integer(forKey: Self.seededVersionKey) < version else { return }
        let tombstones = Set(defaults.stringArray(forKey: Self.deletedSeedsKey) ?? [])
        var added = 0, pinyinAdded = 0, tombstoneSkipped = 0
        for item in items {
            guard let word = item["word"] as? String, !word.isEmpty, word.count <= Self.maxWordLen,
                  let count = item["count"] as? Int, count > 0 else { continue }
            if tombstones.contains(word) {
                tombstoneSkipped += 1
                continue
            }
            if let existing = counts[word] {
                if count > existing { counts[word] = count; indexDirty = true }
            } else {
                counts[word] = count
                added += 1
                indexDirty = true
            }
            if pinyins[word] == nil, let p = item["pinyin"] as? String, Self.isValidPinyin(p) {
                pinyins[word] = p
                pinyinAdded += 1
                indexDirty = true
            }
        }
        if counts.count > Self.maxEntries { trim() }
        defaults.set(counts, forKey: Self.storeKey)
        defaults.set(pinyins, forKey: Self.pinyinStoreKey)
        defaults.set(version, forKey: Self.seededVersionKey)
        DebugLog.log("用户词种子: builtin v\(version) 共 \(items.count) 条,新补词 \(added)/补拼音 \(pinyinAdded)/墓碑跳过 \(tombstoneSkipped)")
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

    /// 打分乘数(词频层): 仅 ≥2 字词参与(了/的/是这类高频虚词不被个人词频顶掉),封顶 ×3;
    /// enabled 由引擎查询入口快照传入(防逐候选读 UserDefaults,热循环实测 +80% 的教训)
    public func boost(_ word: String, enabled: Bool = true) -> Double {
        guard enabled, word.count >= 2, let c = counts[word], c > 0 else { return 1.0 }
        return min(1 + 0.5 * log10(Double(c) + 1), 3.0)
    }

    public func count(_ word: String) -> Int { counts[word] ?? 0 }

    /// 学习键合法性: 每个音节 ≥2 字母(a/o/e 这三个真单字母音节除外)。
    /// 挡住两类脏键: 词典简拼派生键(提交「来」经 "l" 简拼候选,pinyin 字段是 "l" 而非 lai)与
    /// 半截尾音节(「好下=hao x」)——它们会让「d」「hao x」这类输入永远被用户词霸占
    public static func isValidPinyin(_ p: String) -> Bool {
        guard !p.isEmpty, p.count <= 24 else { return false }
        let syls = p.split(separator: " ").map(String.init)
        return !syls.isEmpty && syls.allSatisfy { $0.count >= 2 || $0 == "a" || $0 == "o" || $0 == "e" }
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
