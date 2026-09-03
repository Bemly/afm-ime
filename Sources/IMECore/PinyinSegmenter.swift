import Foundation

/// 拼音切分:把原始按键串切成音节序列(允许最后一个音节不完整)。
/// 例: "jintian" → [jin tian]; "jint"(未打完) → [jin t](t 为不完整尾音节)。
public struct Segmentation {
    public var syllables: [String]
    /// 尾音节是否为不完整前缀
    public var trailingPartial: Bool
}

public struct PinyinSegmenter {
    let syllableSet: Set<String>
    let syllablesSorted: [String] // 按长度降序,用于尾部不完整判断

    public init(syllables: [String]) {
        self.syllableSet = Set(syllables)
        self.syllablesSorted = syllables.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    }

    struct Path {
        var syllables: [String]
        var partial: Bool
    }

    /// 枚举切分方式(动态规划)。每个位置保留 maxPaths 条,
    /// 优先级: 尾部完整 > 音节数少(长词优先) > 字典序,保证最优路径不被截断丢失。
    public func segment(_ input: String, maxPaths: Int = 12) -> [Segmentation] {
        let chars = input.lowercased().map(String.init)
        guard !chars.isEmpty, chars.count <= 40 else { return [] }
        let n = chars.count

        var ways: [[Path]] = .init(repeating: [], count: n + 1)
        ways[n] = [Path(syllables: [], partial: false)]

        for i in stride(from: n - 1, through: 0, by: -1) {
            var seen = Set<[String]>()
            var acc: [Path] = []
            let maxChunk = min(6, n - i)
            for len in 1...maxChunk {
                let chunk = chars[i..<i + len].joined()
                let atEnd = (i + len == n)
                let restList = ways[i + len]
                if restList.isEmpty { continue }
                if syllableSet.contains(chunk) {
                    // 完整音节: 与后缀的各条路径组合(截断取前几条,防爆炸)
                    for rest in restList.prefix(4) {
                        var cand = rest.syllables
                        cand.insert(chunk, at: 0)
                        if seen.insert(cand).inserted {
                            acc.append(Path(syllables: cand, partial: rest.partial))
                        }
                    }
                } else if atEnd, chunk.count < 6, restList.first?.syllables.isEmpty == true {
                    // 不完整尾音节: 只能是最后一块,且必须是某音节的前缀
                    if syllablesSorted.contains(where: { $0.hasPrefix(chunk) }) {
                        if seen.insert([chunk]).inserted {
                            acc.append(Path(syllables: [chunk], partial: true))
                        }
                    }
                }
            }
            // 优先级排序并截断
            acc.sort {
                if $0.partial != $1.partial { return !$0.partial }
                if $0.syllables.count != $1.syllables.count { return $0.syllables.count < $1.syllables.count }
                return $0.syllables.joined() < $1.syllables.joined()
            }
            if acc.count > maxPaths { acc = Array(acc.prefix(maxPaths)) }
            ways[i] = acc
        }
        guard !ways[0].isEmpty else { return [] }
        return ways[0].map { Segmentation(syllables: $0.syllables, trailingPartial: $0.partial) }
    }
}
