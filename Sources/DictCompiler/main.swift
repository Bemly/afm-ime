import Foundation
import Darwin
import IMECore

// rime-ice cn_dicts + 外部词库 → dict.bin v1
// 用法: dictcompiler --cn-dicts <dir> --out <path>
//        [--rime <file>...]        无声调 rime yaml(词\t拼音[\t权重]),如 moegirl / zhwiki
//        [--apostrophe <file>...]  撇号拼音 txt(词\tq'y[\t权重];权重缺省/0 → 100),如 minecraft / BA
//        [--freq <file>...]        词频 TSV(词\t频次 → 自动注音,权重 = clamp(频次, 1...100_000)),如 THUOCL
//        [--wordlist <file>...]    从文本/源码提取引号内 CJK 词 → 自动注音(权重 100),如 ali-words
//        [--md-keywords <file>...] markdown 表第一列关键词(梗合集) → 自动注音(权重 100)
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
/// 可重复标志的全部取值(--flag v1 --flag v2 → [v1, v2])
func repeatedArgs(_ name: String) -> [String] {
    var out: [String] = []
    var i = 1
    while i < args.count {
        if args[i] == name, i + 1 < args.count { out.append(args[i + 1]); i += 2 } else { i += 1 }
    }
    return out
}
guard let dictDir = arg("--cn-dicts"), let outPath = arg("--out") else {
    print("用法: dictcompiler --cn-dicts <cn_dicts目录> --out <dict.bin> [--rime f]... [--apostrophe f]... [--freq f]... [--wordlist f]...")
    exit(2)
}

let t0 = Date()
let fm = FileManager.default
let sylPattern = try! NSRegularExpression(pattern: "^[a-z]+$")

// MARK: - 逐行读取(流式,防 zhwiki 167 万行整体载入内存)

func forEachLine(_ path: String, _ body: (String) -> Void) {
    guard let raw = fm.contents(atPath: path) else { print("!! 无法读取 \(path)"); exit(1) }
    // 优先 UTF-8,失败退 UTF-16(BA 部分文件为 UTF-16)
    guard let text = String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .utf16) else {
        print("!! \(path) 编码无法识别"); exit(1)
    }
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) { body(String(line)) }
}

/// dict.yaml 正文行(`...` 之后,跳过注释/空行),列按 \t 分隔
func forEachYamlRow(_ path: String, _ body: ([String]) -> Void) {
    var inBody = false
    forEachLine(path) { line in
        if !inBody {
            if line.hasPrefix("...") { inBody = true }
            return
        }
        let l = line.trimmingCharacters(in: .whitespaces)
        if l.isEmpty || l.hasPrefix("#") { return }
        body(l.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) })
    }
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
forEachYamlRow(dictDir + "/8105.dict.yaml") { cols in
    guard cols.count >= 2, cols[0].count == 1, let syls = validSyllables(cols[1]), syls.count == 1 else { return }
    let freq = cols.count >= 3 ? (Int64(cols[2]) ?? 100) : 100
    charReadings[cols[0], default: []].append((syls[0], freq))
    charRowCount += 1
}
var charMaxFreq: [String: Int64] = [:]
for (ch, rs) in charReadings { charMaxFreq[ch] = rs.map(\.freq).max() ?? 0 }
print("字表: \(charReadings.count) 字 / \(charRowCount) 读音行 (\(String(format: "%.1f", -t0.timeIntervalSinceNow))s)")

// MARK: - 2) 自动注音(tencent / THUOCL / ali-words 等无拼音词库)

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
/// 音节表只由 rime-ice 主库定义(中文音节集合封闭,主库全覆盖);
/// 外部词库的公式/符号键(nacl/nh/ac)不得进切分表,否则 nhao 会被切成 nh+ao——它们靠缩写直查命中,无需进表
var feedSyllables = true

func accept(_ word: String, _ sylsList: [[String]], _ weight: UInt32) {
    for syls in sylsList {
        let key = syls.joined(separator: " ")
        guard !key.isEmpty, key.utf8.count <= 255 else { continue }
        if feedSyllables {
            for s in syls where s.count > 1 || s == "a" || s == "o" || s == "e" {
                syllables.insert(s) // 单字母键(元素符号 n/h 等)不是真音节,不入表
            }
        }
        merge("\(key)\u{01}\(word)", weight)
        // 简拼键: 各音节首字母连接(rime abbrev 等价,n→你、awsl→啊我死了);
        // 只进 merged,不进 syllables 表(首字母非真音节,会污染切分器)
        let initials = syls.map { String($0.prefix(1)) }.joined()
        if initials != key {
            merge("\(initials)\u{01}\(word)", weight)
        }
    }
}

func merge(_ dedupKey: String, _ weight: UInt32) {
    if let old = merged[dedupKey] {
        dupCount += 1
        merged[dedupKey] = max(old, weight)
    } else {
        merged[dedupKey] = weight
    }
}

struct Source {
    enum Mode {
        case rimeYaml      // 词\t拼音[\t权重]
        case rimeYamlAuto  // 词[\t拼音[\t权重]],无拼音列时自动注音(tencent)
        case apostropheTxt // 词\tq'y[\t权重],撇号/空格分隔音节;权重缺省或 0 → 100
        case freqTSV       // 词\t频次 → 自动注音,权重 clamp 1...100_000
        case wordList      // 提取引号内 CJK 词 → 自动注音,权重 100
        case mdKeywords    // markdown 表第一列(梗合集):顿号拆分、去两端装饰、纯 CJK → 自动注音,权重 100
    }
    let path: String
    let label: String
    let mode: Mode
}

func ingest(_ src: Source) {
    var kept = 0, skipped = 0
    func bump(_ word: String, _ sylsList: [[String]], _ weight: UInt32) {
        kept += sylsList.isEmpty ? 0 : 1
        accept(word, sylsList, weight)
    }

    switch src.mode {
    case .rimeYaml, .rimeYamlAuto:
        let auto = (src.mode == .rimeYamlAuto)
        forEachYamlRow(src.path) { cols in
            guard !cols.isEmpty, !cols[0].isEmpty, cols[0].utf8.count <= 200 else { skipped += 1; return }
            let word = cols[0]
            if let syls = validSyllables(cols.count >= 2 ? cols[1] : "") {
                let weight = cols.count >= 3 ? UInt32(clamping: Int64(cols[2]) ?? 100) : 100
                bump(word, [syls], weight)
            } else if auto, isCJK(word), word.count <= 12 {
                bump(word, annotate(word), 100)
            } else {
                skipped += 1
            }
        }
    case .apostropheTxt:
        forEachLine(src.path) { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") { return }
            let cols = l.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 2, !cols[0].isEmpty, cols[0].utf8.count <= 200 else { skipped += 1; return }
            guard let syls = validSyllables(cols[1].replacingOccurrences(of: "'", with: " ")) else { skipped += 1; return }
            var weight: UInt32 = 100
            if cols.count >= 3, let v = UInt64(cols[2]), v > 0 { weight = UInt32(clamping: v) }
            bump(cols[0], [syls], weight)
        }
    case .freqTSV:
        forEachLine(src.path) { line in
            let cols = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 2, !cols[0].isEmpty, let freq = Int64(cols[1]), freq > 0 else { skipped += 1; return }
            let word = cols[0]
            guard isCJK(word), word.count >= 2, word.count <= 12 else { skipped += 1; return } // 单字 8105 已覆盖
            let list = annotate(word)
            guard !list.isEmpty else { skipped += 1; return }
            bump(word, list, UInt32(clamping: min(freq, 100_000)))
        }
    case .wordList:
        let quoted = try! NSRegularExpression(pattern: "\"([^\"]+)\"")
        guard let raw = fm.contents(atPath: src.path),
              let text = String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .utf16) else {
            print("!! 无法读取 \(src.path)"); exit(1)
        }
        let ns = text as NSString
        var seenWords = Set<String>()
        for m in quoted.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: m.range(at: 1))
            guard !seenWords.contains(word), isCJK(word), word.count >= 2, word.count <= 12 else { continue }
            seenWords.insert(word)
            let list = annotate(word)
            guard !list.isEmpty else { skipped += 1; continue }
            bump(word, list, 100)
        }
    case .mdKeywords:
        forEachLine(src.path) { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("|") else { return }
            let cells = t.components(separatedBy: "|")
            guard cells.count >= 2 else { return }
            let cell = cells[1].trimmingCharacters(in: .whitespaces)
            guard cell != "关键词", !cell.hasPrefix("-") else { return } // 表头/分隔行
            for piece in cell.components(separatedBy: "、") {
                var w = piece.trimmingCharacters(in: .whitespaces)
                // 去两端非 CJK 装饰(⚡/emoji/引号等)
                while let f = w.first, !isCJK(String(f)) { w.removeFirst() }
                while let l = w.last, !isCJK(String(l)) { w.removeLast() }
                guard isCJK(w), w.count >= 2, w.count <= 12 else { continue } // 拉丁/含占位符不可拼音键入,单字 8105 已覆盖
                let list = annotate(w)
                guard !list.isEmpty else { skipped += 1; continue }
                bump(w, list, 100)
            }
        }
    }
    print("\(src.label): 收录 \(kept) 跳过 \(skipped) (\(String(format: "%.1f", -t0.timeIntervalSinceNow))s)")
}

// MARK: - 4) 主流程: rime-ice 主库 + 外部词库

ingest(Source(path: dictDir + "/8105.dict.yaml", label: "8105.dict.yaml", mode: .rimeYaml))
ingest(Source(path: dictDir + "/41448.dict.yaml", label: "41448.dict.yaml", mode: .rimeYaml))
ingest(Source(path: dictDir + "/base.dict.yaml", label: "base.dict.yaml", mode: .rimeYaml))
ingest(Source(path: dictDir + "/ext.dict.yaml", label: "ext.dict.yaml", mode: .rimeYaml))
print("tencent 注音中…")
ingest(Source(path: dictDir + "/tencent.dict.yaml", label: "tencent.dict.yaml", mode: .rimeYamlAuto))
feedSyllables = false // 外部词库不再定义音节(防公式/符号键污染切分表)

for f in repeatedArgs("--rime") {
    ingest(Source(path: f, label: (f as NSString).lastPathComponent, mode: .rimeYaml))
}
for f in repeatedArgs("--apostrophe") {
    ingest(Source(path: f, label: (f as NSString).lastPathComponent, mode: .apostropheTxt))
}
for f in repeatedArgs("--freq") {
    ingest(Source(path: f, label: (f as NSString).lastPathComponent, mode: .freqTSV))
}
for f in repeatedArgs("--wordlist") {
    ingest(Source(path: f, label: (f as NSString).lastPathComponent, mode: .wordList))
}
for f in repeatedArgs("--md-keywords") {
    ingest(Source(path: f, label: (f as NSString).lastPathComponent, mode: .mdKeywords))
}

print("合并去重后: \(merged.count) 条 / 重复 \(dupCount) / 峰值内存 \(String(format: "%.0f", getRSSMB()))MB (\(String(format: "%.1f", -t0.timeIntervalSinceNow))s)")

// MARK: - 5) 排序 + 写文件

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
