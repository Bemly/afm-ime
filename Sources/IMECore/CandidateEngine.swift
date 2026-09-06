import Foundation

/// 候选引擎: 多路切分 + 词典前缀查询 + 打分合并。纯查表,无组句(按词输入,见决策记录)。
/// 打分: weight × 前缀权重(完全匹配 ×1.0 / 延伸词组 ×0.6 / 尾部不完整 ×0.45)。
public final class CandidateEngine {
    public let store: DictStore
    public let segmenter: PinyinSegmenter

    public init(store: DictStore) {
        self.store = store
        self.segmenter = PinyinSegmenter(syllables: store.syllables)
    }

    public struct Candidate {
        public var text: String
        public var pinyin: String
        public var score: Double
        /// 是否覆盖整个输入(全键精确/延伸/模糊/缩写/整句组词)=true;渐进前缀词=false。
        /// 排序先按此档再按分数——词典权重横跨 7 个数量级(ext 梗词 100 vs 高频单字 756 万),
        /// 乘法层级因子(0.1^层)压不住,没绷住(100)会被 没(756万×0.01=7.5万)压到十名开外
        public var coversInput: Bool
        /// 用户词库命中(上屏过的词)——最高优先档,压过一切词典候选
        public var isUser: Bool

        public init(text: String, pinyin: String, score: Double, coversInput: Bool = true, isUser: Bool = false) {
            self.text = text
            self.pinyin = pinyin
            self.score = score
            self.coversInput = coversInput
            self.isUser = isUser
        }
    }

    public func candidates(for rawInput: String, limit: Int = 20) -> [Candidate] {
        let t0 = Date()
        var best: [String: Candidate] = [:]
        var fuzzyVariants: [String] = []
        var userHitCount = 0
        // 设置快照(每查询读一次 UserDefaults;逐候选读实测热循环 +80%)
        let fuzzyOn = UserPrefs.fuzzyPinyin
        let userFreqOn = UserPrefs.userFreq

        // 用户词库: 上屏过的词按其拼音键直查(kb26)——最高优先档,「打得越多权重越高」
        if userFreqOn {
            for uh in UserFreq.shared.hits(key: rawInput, partialPrefix: false) {
                userHitCount += 1
                best[uh.word] = Candidate(text: uh.word, pinyin: uh.pinyin,
                                          score: UserFreq.shared.userScore(count: uh.count), isUser: true)
            }
        }

        // 简拼: 整串字母作为首字母缩写键直查(awsl→啊我死了/阿伟死了,n→你),与音节切分互补;
        // 缩写键由编译期派生(rime abbrev 等价),只取 key 恰好等于输入串的记录
        for hit in store.query(prefix: rawInput, exactCap: 24, extCap: 8, scanBudget: 20_000) {
            guard hit.key == rawInput else { break }
            let score = Double(hit.weight)
            if let old = best[hit.word], old.score >= score { continue }
            best[hit.word] = Candidate(text: hit.word, pinyin: hit.key, score: score)
        }

        let segs = segmenter.segment(rawInput)
        var primaryFullExact = false // 主路径完整键在词库有整句短语 → 不做词格组句
        // 去重: 同档比分数;全覆盖候选永远压过同词的部分覆盖条目;
        // 用户档同文不被词典候选覆盖(用户词永居最高档)
        func upsert(_ nc: Candidate) {
            if let old = best[nc.text] {
                if old.isUser != nc.isUser {
                    if !nc.isUser { return }
                } else if old.coversInput == nc.coversInput {
                    guard old.score < nc.score else { return }
                } else if old.coversInput {
                    return
                }
            }
            best[nc.text] = nc
        }
        for (si, seg) in segs.enumerated() {
            let key = seg.syllables.joined(separator: " ")
            let keyFactor = seg.trailingPartial ? 0.45 : 1.0
            // 模糊拼音: 仅展开前 3 条切分路径,每键变体含原键封顶 8;
            // 模糊命中 ×0.5,保证"首选项是准确拼音"(rime derive 的查询期等价物);设置可关
            var queries: [(key: String, factor: Double)] = [(key, 1.0)]
            if si == 0, fuzzyOn {
                for v in Self.fuzzyKeys(syllables: seg.syllables) where v != key {
                    guard queries.count < 8 else { break }
                    queries.append((v, 0.5))
                    fuzzyVariants.append(v)
                }
            }
            // 单字母缩写音节展开: n+hao → ni/na/ne…+hao(简拼混输),笛卡尔积封顶 16
            // 仅前 2 条短路径(≤4 段且 ≤2 个缩写)展开,长垃圾路径的展开查询无意义
            if si < 2, seg.abbrevFlags.contains(true),
               seg.syllables.count <= 4, seg.abbrevFlags.filter({ $0 }).count <= 2 {
                var products = [""]
                for (i, syl) in seg.syllables.enumerated() {
                    let options = seg.abbrevFlags[i]
                        ? store.syllables.filter { $0.hasPrefix(syl) && $0.count > 1 }
                        : [syl]
                    var next: [String] = []
                    for base in products {
                        for o in options {
                            next.append(base.isEmpty ? o : base + " " + o)
                            if next.count >= 16 { break }
                        }
                        if next.count >= 16 { break }
                    }
                    products = next
                    if products.isEmpty { break }
                }
                for k in products.prefix(16) where k != key {
                    queries.append((k, 0.5))
                    fuzzyVariants.append("缩写:" + k)
                }
            }
            var foundExactMain = false
            var segUserHits = 0
            for q in queries {
                let fuzzy = q.factor < 1.0
                for hit in store.query(prefix: q.key,
                                       exactCap: 32,
                                       extCap: fuzzy ? 48 : 256,
                                       scanBudget: fuzzy ? 20_000 : 60_000) {
                    if si == 0, q.factor == 1.0, hit.key == key { foundExactMain = true }
                    let isExact = hit.key == q.key
                    let score = Double(hit.weight) * (isExact ? 1.0 : 0.6) * keyFactor * q.factor
                    upsert(Candidate(text: hit.word, pinyin: hit.key, score: score))
                }
                // 用户词库: 与本键一致的已上屏词直查(缩写展开键放行=简拼混输能命中,模糊变体键不放行);
                // partialPrefix 允许尾音节未打全(词条拼音以 key 为前缀)
                if !fuzzyVariants.contains(q.key), userFreqOn {
                    for uh in UserFreq.shared.hits(key: q.key, partialPrefix: seg.trailingPartial) {
                        segUserHits += 1
                        upsert(Candidate(text: uh.word, pinyin: uh.pinyin,
                                         score: UserFreq.shared.userScore(count: uh.count), isUser: true))
                    }
                }
            }
            // 宽松兜底: 快路径无命中时逐音节前缀匹配——中间音节没打全(mebengz 的 me⊂mei)与
            // 缩写音节(zhedm 的 d⊂de、m⊂ma)都能命中用户词
            if segUserHits == 0, userFreqOn, seg.trailingPartial || seg.abbrevFlags.contains(true) {
                for uh in UserFreq.shared.looseHits(key: key, limit: 5) {
                    segUserHits += 1
                    upsert(Candidate(text: uh.word, pinyin: uh.pinyin,
                                     score: UserFreq.shared.userScore(count: uh.count), isUser: true))
                }
            }
            userHitCount += segUserHits
            if si == 0, foundExactMain { primaryFullExact = true }
            // 渐进前缀(仅纯全拼路径;因子 0.1^层级,整句/全键词永远排在渐进单词前):
            // 长句打全拼但词库无对应短语时,给出覆盖开头音节的词(nishiyizhimaoniang → 你是一只猫娘(整句) > 你是)
            // 跳过末位为单字母"音节"的层级(元素符号键污染切分表,nhao 不得退化到 n)
            if si < 2, !seg.abbrevFlags.contains(true), seg.syllables.count > 1 {
                var syls = seg.syllables
                for drop in 1...min(4, syls.count - 1) {
                    syls.removeLast()
                    if syls.last?.count == 1 { continue }
                    let pk = syls.joined(separator: " ")
                    for hit in store.query(prefix: pk, exactCap: 12, extCap: 2, scanBudget: 5_000) {
                        guard hit.key == pk else { continue } // 只要完整覆盖前缀的词
                        let score = Double(hit.weight) * pow(0.1, Double(drop))
                        upsert(Candidate(text: hit.word, pinyin: hit.key, score: score, coversInput: false))
                    }
                }
            }
        }
        // 整句组词: 主路径纯全拼、词库无整句短语时,词格 DP 用词典词覆盖全部音节
        // (nishiyizhiwanjuxiong → 你是一只玩具熊 = 你+是+一只+玩具+熊),排在渐进单词前,FM ✦ 到达后置顶
        if !primaryFullExact, let seg0 = segs.first, !seg0.abbrevFlags.contains(true),
           seg0.syllables.count >= 2, seg0.syllables.count <= 12,
           let sent = composeSentence(syllables: seg0.syllables) {
            if let old = best[sent.text], old.coversInput, old.score >= sent.score {
                // 已有同文全覆盖候选(如词典整句)保持
            } else {
                best[sent.text] = sent
            }
        }
        var ranked = Array(best.values)
        for i in ranked.indices { ranked[i].score *= UserFreq.shared.boost(ranked[i].text, enabled: userFreqOn) } // 用户词频: 档内选用越多越靠前
        // 三档排序: 用户词库命中(最高,压过一切词典候选) > 全键覆盖 > 渐进前缀;档内按分数
        func tier(_ c: Candidate) -> Int { c.isUser ? 2 : (c.coversInput ? 1 : 0) }
        let out = Array(ranked.sorted { a, b in
            tier(a) != tier(b) ? tier(a) > tier(b) : a.score > b.score
        }.prefix(limit))
        DebugLog.log("引擎[\(rawInput)] 切分=\(segs.map { $0.syllables.joined(separator: "'") }.joined(separator: " / ")) → \(out.count) 条"
            + (userFreqOn ? "" : " 用户词库关")
            + (userHitCount > 0 ? " 用户词\(userHitCount)" : "")
            + (fuzzyOn ? "" : " 模糊关")
            + (fuzzyVariants.isEmpty ? "" : " 模糊=\(fuzzyVariants.joined(separator: ","))")
            + ", \(String(format: "%.2f", -t0.timeIntervalSinceNow * 1000))ms")
        return out
    }

    /// 整句组词(词格 DP/Viterbi): 在音节序列上用词典词覆盖全部音节,
    /// 目标 max 平均(log(w) + 词长加成min(字数−1,3))(按词数归一,多字词稳定压过同音高频单字组合,
    /// zhwiki 长标题也抢不过自然组句);得分 = exp(平均 logW);FM ✦ 到达后置顶纠同音
    func composeSentence(syllables: [String]) -> Candidate? {
        let n = syllables.count
        guard n >= 2, n <= 12 else { return nil }
        var spanCache: [String: (word: String, logW: Double)?] = [:]
        func bestWord(_ i: Int, _ j: Int) -> (word: String, logW: Double)? {
            let key = syllables[i..<j].joined(separator: " ")
            if let c = spanCache[key] { return c }
            let hit = store.query(prefix: key, exactCap: 4, extCap: 1, scanBudget: 5_000)
                .first { $0.key == key } // 该音节段权重最高的词典词
            let r: (word: String, logW: Double)? = hit.map {
                ($0.word, log(Double($0.weight) + 1) + Double(min($0.word.count - 1, 3)))
            }
            spanCache[key] = r
            return r
        }
        // bestTotal[j][c] = 用 c 个词覆盖前 j 个音节的最大 ΣlogW;回溯表同维
        var bestTotal = Array(repeating: [Double](repeating: -.infinity, count: n + 1), count: n + 1)
        var backWord = Array(repeating: [String](repeating: "", count: n + 1), count: n + 1)
        var backStart = Array(repeating: [Int](repeating: -1, count: n + 1), count: n + 1)
        bestTotal[0][0] = 0
        for j in 1...n {
            for i in (0..<j).reversed() {
                guard let r = bestWord(i, j) else { continue }
                for c in 0...(j - 1) where bestTotal[i][c] > -.infinity {
                    let t = bestTotal[i][c] + r.logW
                    if t > bestTotal[j][c + 1] {
                        bestTotal[j][c + 1] = t
                        backWord[j][c + 1] = r.word
                        backStart[j][c + 1] = i
                    }
                }
            }
        }
        var bestAvg = -Double.infinity, bestC = 0
        for c in 1...n where bestTotal[n][c] > -.infinity {
            let avg = bestTotal[n][c] / Double(c)
            if avg > bestAvg { bestAvg = avg; bestC = c }
        }
        guard bestC > 0 else { return nil }
        var words: [String] = []
        var j = n, c = bestC
        while j > 0, c > 0 {
            let i = backStart[j][c]
            guard i >= 0 else { return nil }
            words.insert(backWord[j][c], at: 0)
            j = i
            c -= 1
        }
        let text = words.joined()
        guard !text.isEmpty else { return nil }
        return Candidate(text: text,
                         pinyin: syllables.joined(separator: " "),
                         score: exp(bestAvg))
    }

    /// 单音节的模糊变体: zh↔z ch↔c sh↔s + 前后鼻音 an↔ang en↔eng in↔ing
    /// (按后缀匹配,ian↔iang、uan↔uang 自然覆盖;≥2 字符才处理,单字母尾片段跳过)
    static func fuzzySyllables(of syl: String) -> [String] {
        guard syl.count >= 2 else { return [] }
        var out: [String] = []
        switch true {
        case syl.hasPrefix("zh"): out.append("z" + syl.dropFirst(2))
        case syl.hasPrefix("ch"): out.append("c" + syl.dropFirst(2))
        case syl.hasPrefix("sh"): out.append("s" + syl.dropFirst(2))
        case syl.hasPrefix("z"): out.append("zh" + syl.dropFirst(1))
        case syl.hasPrefix("c"): out.append("ch" + syl.dropFirst(1))
        case syl.hasPrefix("s"): out.append("sh" + syl.dropFirst(1))
        default: break
        }
        for (front, back) in [("ang", "an"), ("eng", "en"), ("ing", "in"),
                              ("an", "ang"), ("en", "eng"), ("in", "ing")] {
            if syl.hasSuffix(front) {
                out.append(String(syl.dropLast(front.count)) + back)
                break
            }
        }
        return out
    }

    /// 整键的模糊变体: 各音节变体的笛卡尔积(含原键封顶 8)
    static func fuzzyKeys(syllables: [String]) -> [String] {
        var acc = [""]
        for syl in syllables {
            var variants = [syl]
            if syl.count >= 2 { variants.append(contentsOf: fuzzySyllables(of: syl)) }
            var next: [String] = []
            for base in acc {
                for v in variants {
                    next.append(base.isEmpty ? v : base + " " + v)
                    if next.count >= 8 { break }
                }
                if next.count >= 8 { break }
            }
            acc = next
        }
        return Array(acc.dropFirst())
    }
}
