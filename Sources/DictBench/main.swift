import Foundation
import IMECore

// 词库加载/查询基准
// 用法: dictbench [dict.bin]

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Data/dict.bin"

let t0 = Date()
let store = try DictStore(url: URL(fileURLWithPath: path))
let loadMs = -t0.timeIntervalSinceNow * 1000
print("加载: \(String(format: "%.1f", loadMs))ms | 记录 \(store.recordCount) | 音节 \(store.syllables.count)")
print("---")

let engine = CandidateEngine(store: store)

let queries = [
    "nihao", "jintian", "gongyuan", "ninhao", "ceshi",
    "ceshijieguo",                        // 4 字词组
    "ni", "z",                            // 短前缀(最坏情况)
    "jint",                               // 尾音节不完整
]
for q in queries {
    let tq = Date()
    let cands = engine.candidates(for: q, limit: 6)
    let dt = -tq.timeIntervalSinceNow * 1000
    print("「\(q)」 \(String(format: "%.1f", dt))ms")
    for c in cands { print("    \(c.text)  [\(c.pinyin)] score=\(Int(c.score))") }
}

// 热循环: 模拟连续打字的查询负载
let hot = ["jintian", "nihao", "shijie", "zhongguo", "beijing", "gongyuan", "xihuan", "kaixin"]
var total = 0.0, worst = 0.0, n = 0
for round in 0..<40 {
    let prefix = hot[round % hot.count]
    let input = String(prefix.prefix(1 + round % max(1, prefix.count)))
    let tq = Date()
    _ = engine.candidates(for: input, limit: 10)
    let dt = -tq.timeIntervalSinceNow * 1000
    total += dt; worst = max(worst, dt); n += 1
}
print("---")
print("热循环 \(n) 次: 平均 \(String(format: "%.2f", total / Double(n)))ms / 最差 \(String(format: "%.2f", worst))ms")
