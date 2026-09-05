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
    // 外部词库回归(2026-09 外部词库接入): minecraft/BA/THUOCL/ali-words
    "kulipa",                             // mcwiki 苦力怕
    "xiajiehejin",                        // mcwiki 下界合金
    "fumo",                               // mcwiki 附魔
    "weilandangan",                       // 蔚蓝档案(BA)
    "qinghuishi",                         // 青辉石(BA)
    "zifuchuan",                          // THUOCL 字符串
    "huashetianzu",                       // THUOCL 成语
    "funeng",                             // ali-words 赋能
    "zundujiadu",                         // 梗合集 尊嘟假嘟
    "taikula",                            // 梗合集 泰裤辣
    "caijiuduolian",                      // 梗合集 菜就多练
    "hongwen",                            // 梗合集 红温
    "malou",                              // 梗合集 吗喽
    "saxibuli",                           // 空耳词库 撒西不理(sa xi bu li)
    "yamadie",                            // 空耳词库 亚麻跌
    "zongguo",                            // 模糊音 zh→z: 应出 中国(排在精确 zong 词之后)
    "sibie",                              // 模糊音 sh→s: 应出 识别
    "shen",                               // 模糊音 双向: 深/身 在前,生/声(×0.5)在后
    "zhuaba",                             // 热词 爪巴
    "pingguo",                            // 符号 苹果标志
    "xiaolian",                           // 符号 ☻ + 😀(emoji 2000)
    "gun",                                // 符号 丨(与 滚 同键,权重排序)
    "shoubiao",                           // emoji ⌚
    "awsl",                               // 简拼: 啊我死了/阿伟死了
    "nh",                                 // 简拼: 女孩/您好
    "nhao",                               // 简拼混输: n+hao → 你好
    "nishiyizhimaoniang",                 // 渐进前缀: 你是X 系列词
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
