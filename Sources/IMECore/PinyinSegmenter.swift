import Foundation

/// 拼音切分:把原始按键串切成音节序列(允许最后一个音节不完整)。
/// 例: "jintian" → [jin tian]; "jint"(未打完) → [jin t](t 为不完整尾音节)。
/// 单字母缩写: 非音节单字母(b/c/d/f/g/h/j/k/l/m/n/p/q/r/s/t/v/w/x/y/z)可出现在
/// 任意位置,作为"同首字母音节"的缩写(n+hao→你好),由引擎展开查询(简拼混输)。
public struct Segmentation {
    public var syllables: [String]
    /// 尾音节是否为不完整前缀
    public var trailingPartial: Bool
    /// 与 syllables 平行: 该位是否为单字母缩写(需引擎展开)
    public var abbrevFlags: [Bool]
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
        var abbrevFlags: [Bool]
        var abbrevCount: Int
    }

    /// 枚举切分方式(动态规划)。每个位置保留 maxPaths 条,
    /// 优先级: 缩写少 > 尾部完整 > 音节数少(长词优先) > 字典序,保证最优路径不被截断丢失。
    public func segment(_ input: String, maxPaths: Int = 12) -> [Segmentation] {
        let chars = input.lowercased().map(String.init)
        guard !chars.isEmpty, chars.count <= 40 else { return [] }
        let n = chars.count

        var ways: [[Path]] = .init(repeating: [], count: n + 1)
        ways[n] = [Path(syllables: [], partial: false, abbrevFlags: [], abbrevCount: 0)]

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
                            var ab = rest.abbrevFlags
                            ab.insert(false, at: 0)
                            acc.append(Path(syllables: cand, partial: rest.partial,
                                            abbrevFlags: ab, abbrevCount: rest.abbrevCount))
                        }
                    }
                } else if atEnd, chunk.count < 6, restList.first?.syllables.isEmpty == true,
                          syllablesSorted.contains(where: { $0.hasPrefix(chunk) }) {
                    // 不完整尾音节: 只能是最后一块,且必须是某音节的前缀
                    if seen.insert([chunk]).inserted {
                        acc.append(Path(syllables: [chunk], partial: true, abbrevFlags: [false], abbrevCount: 0))
                    }
                } else if chunk.count == 1,
                          syllablesSorted.contains(where: { $0.hasPrefix(chunk) }) {
                    // 单字母缩写(非音节): 可出现在任意位置,引擎展开为同首字母音节
                    for rest in restList.prefix(4) {
                        var cand = rest.syllables
                        cand.insert(chunk, at: 0)
                        if seen.insert(cand).inserted {
                            var ab = rest.abbrevFlags
                            ab.insert(true, at: 0)
                            acc.append(Path(syllables: cand, partial: rest.partial,
                                            abbrevFlags: ab, abbrevCount: rest.abbrevCount + 1))
                        }
                    }
                }
            }
            // 优先级排序并截断
            acc.sort {
                if $0.abbrevCount != $1.abbrevCount { return $0.abbrevCount < $1.abbrevCount }
                if $0.partial != $1.partial { return !$0.partial }
                if $0.syllables.count != $1.syllables.count { return $0.syllables.count < $1.syllables.count }
                return $0.syllables.joined() < $1.syllables.joined()
            }
            if acc.count > maxPaths { acc = Array(acc.prefix(maxPaths)) }
            ways[i] = acc
        }
        guard !ways[0].isEmpty else { return [] }
        return ways[0].map {
            Segmentation(syllables: $0.syllables, trailingPartial: $0.partial, abbrevFlags: $0.abbrevFlags)
        }
    }
}
