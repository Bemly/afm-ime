import Foundation
import Darwin
import IMECore

// rime-ice cn_dicts → dict.bin v1
// 用法: dictcompiler --cn-dicts <dir> --out <path>
// - 8105.dict.yaml 作为单字注音表(多音字多行,取字频比 ≥5% 的读音参与注音,与 rime 同策略)
// - base/ext/41448/8105 自带拼音直接收录;tencent 单列词库自动注音
// - 合并去重 (key,word) 取 max(weight);Records 按 (key, weight 降序, word) 排序写入

struct Entry {
    var key: [UInt8]   // 音节以单空格连接
    var word: [UInt8]
    var weight: UInt32
}

let args = CommandLine.arguments
func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
guard let dictDir = arg("--cn-dicts"), let outPath = arg("--out") else {
    print("用法: dictcompiler --cn-dicts <cn_dicts目录> --out <dict.bin>")
    exit(2)
}

let t0 = Date()
let fm = FileManager.default
let sylPattern = try! NSRegularExpression(pattern: "^[a-z]+$")

// MARK: - dict.yaml 解析

/// 返回 `...` 之后的词条行(跳过注释/空行),列按 \t 分隔
func parseYaml(_ path: String) -> [[String]] {
    guard let raw = fm.contents(atPath: path), let text = String(data: raw, encoding: .utf8) else {
        print("!! 无法读取 \(path)"); exit(1)
    }
    var rows: [[String]] = []
    var inBody = false
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if !inBody {
            if line.hasPrefix("...") { inBody = true }
            continue
        }
        let l = line.trimmingCharacters(in: .whitespaces)
        if l.isEmpty || l.hasPrefix("#") { continue }
        rows.append(l.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) })
    }
    return rows
}

func validSyllables(_ col: String) -> [String]? {
    var out: [String] = []
    for s in col.split(separator: " ") {
        let syl = String(s).lowercased()
        guard sylPattern.firstMatch(in: syl, range: NSRange(syl.startIndex..., in: syl)) != nil else { return nil }
        out.append(syl)
    }
    return out.isEmpty ? nil : out
}

// MARK: - 1) 单字注音表(8105)

var charReadings: [String: [(reading: String, freq: Int64)]] = [:]
var charRowCount = 0
for cols in parseYaml(dictDir + "/8105.dict.yaml") {
    guard cols.count >= 2, cols[0].count == 1, let syls = validSyllables(cols[1]), syls.count == 1 else { continue }
    let freq = cols.count >= 3 ? (Int64(cols[2]) ?? 100) : 100
    charReadings[cols[0], default: []].append((syls[0], freq))
    charRowCount += 1
}
var charMaxFreq: [String: Int64] = [:]
for (ch, rs) in charReadings { charMaxFreq[ch] = rs.map(\.freq).max() ?? 0 }
print("字表: \(charReadings.count) 字 / \(charRowCount) 读音行 (\(String(format: "%.1f", -t0.timeIntervalSinceNow))s)")

// MARK: - 2) 自动注音(tencent 单列词库)

/// 对无拼音词条生成 ≤4 组音节组合(beam,按各字字频乘积排序)
func annotate(_ word: String) -> [[String]] {
    var perChar: [[(reading: String, freq: Int64)]] = []
    for ch in word {
        guard let rs = charReadings[String(ch)] else { return [] } // 有字不在字表 → 放弃该词
        let maxF = charMaxFreq[String(ch)] ?? 0
        var keep = rs.filter { Double($0.freq) >= 0.05 * Double(maxF) }
        if keep.isEmpty { keep = [rs.max { $0.freq < $1.freq }!] }
        perChar.append(keep.sorted { $0.freq > $1.freq })
    }
    guard !perChar.isEmpty, perChar.count <= 12 else { return [] }
    var beam: [([String], Double)] = [([], 1.0)]
    for readings in perChar {
        var next: [([String], Double)] = []
        for (prefix, p) in beam.prefix(8) {
            for r in readings.prefix(4) {
                next.append((prefix + [r.reading], p * Double(max(1, r.freq))))
            }
        }
        next.sort { $0.1 > $1.1 }
        beam = Array(next.prefix(6))
    }
    var out: [[String]] = []
    var seen = Set<[String]>()
    for (syls, _) in beam {
        if seen.insert(syls).inserted { out.append(syls) }
        if out.count == 4 { break }
    }
    return out
}

func isCJK(_ word: String) -> Bool {
    if word.isEmpty { return false }
    for sc in word.unicodeScalars {
        let v = sc.value
        if !(0x4E00...0x9FFF).contains(v) && !(0x3400...0x4DBF).contains(v) && v != 0x3007 { return false }
    }
    return true
}

// MARK: - 3) 汇总 + 去重

var merged: [String: UInt32] = [:] // "key\x01word" -> max weight
var syllables = Set<String>()
var dupCount = 0

func ingest(_ file: String, annotated: Bool) {
    var kept = 0, skipped = 0
    for cols in parseYaml(dictDir + "/" + file) {
        guard !cols.isEmpty, !cols[0].isEmpty, cols[0].utf8.count <= 200 else { skipped += 1; continue }
        let word = cols[0]
        var sylsList: [[String]] = []
        if annotated {
            if let syls = validSyllables(cols.count >= 2 ? cols[1] : "") { sylsList = [syls] }
        } else {
            let list = annotate(word)
            guard isCJK(word), !list.isEmpty else { skipped += 1; continue }
            sylsList = list
        }
        guard !sylsList.isEmpty else { skipped += 1; continue }
        let weight = cols.count >= 3 ? UInt32(clamping: Int64(cols[2]) ?? 100) : 100
        for syls in sylsList {
            let key = syls.joined(separator: " ")
            guard !key.isEmpty, key.utf8.count <= 255 else { continue }
            for s in syls { syllables.insert(s) }
            let dedupKey = "\(key)\u{01}\(word)"
            if let old = merged[dedupKey] {
                dupCount += 1
                merged[dedupKey] = max(old, weight)
            } else {
                merged[dedupKey] = weight
            }
            kept += 1
        }
    }
    print("\(file): 收录 \(kept) 跳过 \(skipped) (\(String(format: "%.1f", -t0.timeIntervalSinceNow))s)")
}

ingest("8105.dict.yaml", annotated: true)
ingest("41448.dict.yaml", annotated: true)
ingest("base.dict.yaml", annotated: true)
ingest("ext.dict.yaml", annotated: true)
print("tencent 注音中…")
ingest("tencent.dict.yaml", annotated: false)

print("合并去重后: \(merged.count) 条 / 重复 \(dupCount) / 峰值内存 \(String(format: "%.0f", getRSSMB()))MB (\(String(format: "%.1f", -t0.timeIntervalSinceNow))s)")

// MARK: - 4) 排序 + 写文件

var entries: [Entry] = merged.map { kv in
    let parts = kv.key.split(separator: "\u{01}", maxSplits: 1, omittingEmptySubsequences: false)
    return Entry(key: Array(parts[0].utf8), word: Array(parts[1].utf8), weight: kv.value)
}
merged.removeAll()

entries.sort { a, b in
    let m = min(a.key.count, b.key.count)
    let c = memcmp(a.key, b.key, m)
    if c != 0 { return c < 0 }
    if a.key.count != b.key.count { return a.key.count < b.key.count }
    if a.weight != b.weight { return a.weight > b.weight }
    return memcmp(a.word, b.word, min(a.word.count, b.word.count)) < 0
}

var syllableList = syllables.sorted()
syllables.removeAll()

var sylBlob: [UInt8] = []
for s in syllableList {
    let b = Array(s.utf8)
    sylBlob.append(UInt8(b.count & 0xFF)); sylBlob.append(UInt8((b.count >> 8) & 0xFF))
    sylBlob.append(contentsOf: b)
}
let offsetsOffset = DictFormat.headerSize
let syllablesOffset = offsetsOffset + 8 * entries.count
let recordsOffset = syllablesOffset + sylBlob.count

var offsets: [UInt64] = []
offsets.reserveCapacity(entries.count)
var cursor = recordsOffset
var recordBlob = [UInt8]()
recordBlob.reserveCapacity(entries.count * 28)
func leBytes64(_ v: UInt64) -> [UInt8] {
    var x = v.littleEndian
    return withUnsafeBytes(of: &x) { Array($0) }
}
func leBytes32(_ v: UInt32) -> [UInt8] {
    var x = v.littleEndian
    return withUnsafeBytes(of: &x) { Array($0) }
}
func appendLE64(_ v: UInt64, to d: inout Data) { d.append(contentsOf: leBytes64(v)) }
func appendLE32(_ v: UInt32, to d: inout Data) { d.append(contentsOf: leBytes32(v)) }

for e in entries {
    offsets.append(UInt64(cursor))
    let recLen = 1 + e.key.count + 1 + e.word.count + 4
    cursor += recLen
    recordBlob.append(UInt8(e.key.count))
    recordBlob.append(contentsOf: e.key)
    recordBlob.append(UInt8(e.word.count))
    recordBlob.append(contentsOf: e.word)
    recordBlob.append(contentsOf: leBytes32(e.weight))
}
precondition(cursor == recordsOffset + recordBlob.count)

var out = Data(capacity: cursor)
appendLE32(DictFormat.magic, to: &out)
appendLE32(DictFormat.version, to: &out)
appendLE64(UInt64(entries.count), to: &out)
appendLE64(UInt64(offsetsOffset), to: &out)
appendLE64(UInt64(syllableList.count), to: &out)
appendLE64(UInt64(syllablesOffset), to: &out)
for o in offsets { out.append(contentsOf: leBytes64(o)) }
out.append(contentsOf: sylBlob)
out.append(contentsOf: recordBlob)
try! out.write(to: URL(fileURLWithPath: outPath), options: .atomic)

let w = entries.map { Int($0.weight) }.sorted(by: >)
let fileSizeMB = String(format: "%.1f", Double(out.count) / 1048576)
let elapsed = String(format: "%.1f", -t0.timeIntervalSinceNow)
print("完成: \(outPath)")
print("  记录数: \(entries.count)  音节数: \(syllableList.count)  文件: \(fileSizeMB)MB")
print("  权重P50/P90/P99: \(w[w.count/2]) / \(w[w.count/10]) / \(w[w.count/100])")
print("  总耗时: \(elapsed)s")

func getRSSMB() -> Double {
    var info = rusage()
    getrusage(RUSAGE_SELF, &info)
    return Double(info.ru_maxrss) / 1048576
}
