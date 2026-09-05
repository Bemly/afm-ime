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

        public init(text: String, pinyin: String, score: Double) {
            self.text = text
            self.pinyin = pinyin
            self.score = score
        }
    }

    public func candidates(for rawInput: String, limit: Int = 20) -> [Candidate] {
        let t0 = Date()
        var best: [String: Candidate] = [:]
        var fuzzyVariants: [String] = []

        // 简拼: 整串字母作为首字母缩写键直查(awsl→啊我死了/阿伟死了,n→你),与音节切分互补;
        // 缩写键由编译期派生(rime abbrev 等价),只取 key 恰好等于输入串的记录
        for hit in store.query(prefix: rawInput, exactCap: 24, extCap: 8, scanBudget: 20_000) {
            guard hit.key == rawInput else { break }
            let score = Double(hit.weight)
            if let old = best[hit.word], old.score >= score { continue }
            best[hit.word] = Candidate(text: hit.word, pinyin: hit.key, score: score)
        }

        let segs = segmenter.segment(rawInput)
        for (si, seg) in segs.enumerated() {
            let key = seg.syllables.joined(separator: " ")
            let keyFactor = seg.trailingPartial ? 0.45 : 1.0
            // 模糊拼音: 仅展开前 3 条切分路径,每键变体含原键封顶 8;
            // 模糊命中 ×0.5,保证"首选项是准确拼音"(rime derive 的查询期等价物)
            var queries: [(key: String, factor: Double)] = [(key, 1.0)]
            if si < 3 {
                for v in Self.fuzzyKeys(syllables: seg.syllables) where v != key {
                    guard queries.count < 8 else { break }
                    queries.append((v, 0.5))
                    fuzzyVariants.append(v)
                }
            }
            for q in queries {
                let fuzzy = q.factor < 1.0
                for hit in store.query(prefix: q.key,
                                       exactCap: 32,
                                       extCap: fuzzy ? 48 : 256,
                                       scanBudget: fuzzy ? 20_000 : 60_000) {
                    let isExact = hit.key == q.key
                    let score = Double(hit.weight) * (isExact ? 1.0 : 0.6) * keyFactor * q.factor
                    if let old = best[hit.word], old.score >= score { continue }
                    best[hit.word] = Candidate(text: hit.word, pinyin: hit.key, score: score)
                }
            }
        }
        let out = Array(best.values.sorted { $0.score > $1.score }.prefix(limit))
        DebugLog.log("引擎[\(rawInput)] 切分=\(segs.map { $0.syllables.joined(separator: "'") }.joined(separator: " / ")) → \(out.count) 条"
            + (fuzzyVariants.isEmpty ? "" : " 模糊=\(fuzzyVariants.joined(separator: ","))")
            + ", \(String(format: "%.2f", -t0.timeIntervalSinceNow * 1000))ms")
        return out
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
