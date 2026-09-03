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
    }

    public func candidates(for rawInput: String, limit: Int = 20) -> [Candidate] {
        let t0 = Date()
        let segs = segmenter.segment(rawInput)
        guard !segs.isEmpty else {
            DebugLog.log("引擎[\(rawInput)] 无合法切分")
            return []
        }

        var best: [String: Candidate] = [:]
        for seg in segs {
            let key = seg.syllables.joined(separator: " ")
            let keyFactor = seg.trailingPartial ? 0.45 : 1.0
            for hit in store.query(prefix: key) {
                let isExact = hit.key == key
                let score = Double(hit.weight) * (isExact ? 1.0 : 0.6) * keyFactor
                if let old = best[hit.word], old.score >= score { continue }
                best[hit.word] = Candidate(text: hit.word, pinyin: hit.key, score: score)
            }
        }
        let out = Array(best.values.sorted { $0.score > $1.score }.prefix(limit))
        DebugLog.log("引擎[\(rawInput)] 切分=\(segs.map { $0.syllables.joined(separator: "'") }.joined(separator: " / ")) → \(out.count) 条, \(String(format: "%.2f", -t0.timeIntervalSinceNow * 1000))ms")
        return out
    }
}
