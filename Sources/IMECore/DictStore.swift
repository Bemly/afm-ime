import Foundation

/// dict.bin 的 mmap 零拷贝读取器。
/// data 持有映射区域,所有查询在 withUnsafeBytes 内完成;加载耗时 = mmap 时间。
public final class DictStore {
    public let data: Data
    public let recordCount: Int
    public let syllables: [String]
    public lazy var syllableSet: Set<String> = Set(syllables)

    private let offsetsOffset: Int
    private let syllablesOffset: Int

    public struct Hit {
        public var word: String
        public var key: String
        public var weight: UInt32
    }

    public init(url: URL) throws {
        let d = try Data(contentsOf: url, options: [.alwaysMapped])
        guard d.count >= DictFormat.headerSize else { throw DictError.corrupt("文件过小") }
        self.data = d
        var magic: UInt32 = 0, version: UInt32 = 0
        var rc = 0, oo = 0, sc = 0, so = 0
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.baseAddress!
            magic = p.loadUnaligned(fromByteOffset: DictFormat.offMagic, as: UInt32.self)
            version = p.loadUnaligned(fromByteOffset: DictFormat.offVersion, as: UInt32.self)
            rc = Int(p.loadUnaligned(fromByteOffset: DictFormat.offRecordCount, as: UInt64.self))
            oo = Int(p.loadUnaligned(fromByteOffset: DictFormat.offOffsetsOffset, as: UInt64.self))
            sc = Int(p.loadUnaligned(fromByteOffset: DictFormat.offSyllableCount, as: UInt64.self))
            so = Int(p.loadUnaligned(fromByteOffset: DictFormat.offSyllablesOffset, as: UInt64.self))
        }
        guard magic == DictFormat.magic, version == DictFormat.version else {
            throw DictError.corrupt("magic/version 不匹配")
        }
        self.recordCount = rc
        self.offsetsOffset = oo
        self.syllablesOffset = so
        var syl: [String] = []
        syl.reserveCapacity(sc)
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var off = so
            for _ in 0..<sc {
                let len = Int(raw[off]) | (Int(raw[off + 1]) << 8)
                off += 2
                syl.append(String(decoding: raw[off..<off + len], as: UTF8.self))
                off += len
            }
        }
        self.syllables = syl
    }

    public enum DictError: Error {
        case corrupt(String)
    }

    // MARK: - 记录访问(在 withUnsafeBytes 内使用)

    private func readRecord(_ raw: UnsafeRawBufferPointer, index: Int) -> DictFormat.Record {
        let off = Int(loadU64(raw, offsetsOffset + index * 8))
        let keyLen = Int(raw[off])
        let wordLen = Int(raw[off + 1 + keyLen])
        let weight = loadU32(raw, off + 1 + keyLen + 1 + wordLen)
        return DictFormat.Record(
            keyStart: off + 1, keyLen: keyLen,
            wordStart: off + 1 + keyLen + 1, wordLen: wordLen, weight: weight)
    }

    private func loadU64(_ raw: UnsafeRawBufferPointer, _ off: Int) -> UInt64 {
        raw.loadUnaligned(fromByteOffset: off, as: UInt64.self)
    }
    private func loadU32(_ raw: UnsafeRawBufferPointer, _ off: Int) -> UInt32 {
        raw.loadUnaligned(fromByteOffset: off, as: UInt32.self)
    }

    /// key 字节与目标字节比较: -1/0/1
    private func cmpKey(_ raw: UnsafeRawBufferPointer, _ rec: DictFormat.Record, _ target: [UInt8]) -> Int {
        let n = min(rec.keyLen, target.count)
        for i in 0..<n {
            let a = raw[rec.keyStart + i], b = target[i]
            if a != b { return a < b ? -1 : 1 }
        }
        if rec.keyLen == target.count { return 0 }
        return rec.keyLen < target.count ? -1 : 1
    }

    /// 二分查找第一个 key >= target 的记录下标
    private func lowerBound(_ raw: UnsafeRawBufferPointer, _ target: [UInt8]) -> Int {
        var lo = 0, hi = recordCount
        while lo < hi {
            let mid = (lo + hi) / 2
            if cmpKey(raw, readRecord(raw, index: mid), target) < 0 { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    // MARK: - 查询

    /// 前缀查询: 返回 key 以 `prefix` 开头(含完全相等)的记录。
    /// exactCap: 完全匹配 key 最多返回条数(该 key 内部已按 weight 降序)。
    /// extCap: 延伸 key(如 "jin tian qi" 之于 "jin tian")每个 key 只取 top-1,最多 extCap 个 key。
    /// scanBudget: 扫描记录数上限(防短前缀全库扫描)。
    public func query(
        prefix: String, exactCap: Int = 32, extCap: Int = 256, scanBudget: Int = 60_000
    ) -> [Hit] {
        let target = Array(prefix.utf8)
        var hits: [Hit] = []
        var lastKeyStart = -1, lastKeyLen = -1
        var scanned = 0, extCount = 0

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var i = lowerBound(raw, target)
            // 跳过 exact 块之外 Nothing—— lowerBound 已就位
            while i < recordCount, scanned < scanBudget, extCount < extCap {
                let rec = readRecord(raw, index: i)
                // key 必须 >= target 且以 target 开头,否则越界结束
                guard rec.keyLen >= target.count else { break }
                var isPrefix = true
                for j in 0..<target.count where raw[rec.keyStart + j] != target[j] { isPrefix = false; break }
                guard isPrefix else { break }

                let isExact = rec.keyLen == target.count
                if isExact {
                    if hits.count < exactCap + extCap {
                        hits.append(Hit(
                            word: String(decoding: raw[rec.wordStart..<rec.wordStart + rec.wordLen], as: UTF8.self),
                            key: String(decoding: raw[rec.keyStart..<rec.keyStart + rec.keyLen], as: UTF8.self),
                            weight: rec.weight))
                    }
                } else {
                    // 延伸 key: 每 key 只取第一条(即该 key 下 weight 最高者)
                    if rec.keyStart != lastKeyStart || rec.keyLen != lastKeyLen {
                        lastKeyStart = rec.keyStart; lastKeyLen = rec.keyLen
                        extCount += 1
                        hits.append(Hit(
                            word: String(decoding: raw[rec.wordStart..<rec.wordStart + rec.wordLen], as: UTF8.self),
                            key: String(decoding: raw[rec.keyStart..<rec.keyStart + rec.keyLen], as: UTF8.self),
                            weight: rec.weight))
                    }
                }
                i += 1
                scanned += 1
            }
        }
        return hits
    }
}
