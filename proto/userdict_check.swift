import IMECore
import Foundation

let store = try! DictStore(url: URL(fileURLWithPath: "Data/dict.bin"))
let engine = CandidateEngine(store: store)

func show(_ raw: String) {
    let cands = engine.candidates(for: raw, limit: 3)
    print("[\(raw)] " + cands.map { "\($0.text)" + ($0.isUser ? "⭐" : "") }.joined(separator: "  "))
}

print("=== 记录前 ===")
show("mebengz"); show("woc"); show("zhedm"); show("buyaobuy"); show("gongn"); show("zhendchoux")

UserFreq.shared.record("没绷住", pinyin: "mei beng zhu")
UserFreq.shared.record("我草", pinyin: "wo cao")
UserFreq.shared.record("真的吗", pinyin: "zhen de ma")
UserFreq.shared.record("不要不要", pinyin: "bu yao bu yao")
UserFreq.shared.record("功能", pinyin: "gong neng")
UserFreq.shared.record("真的抽象", pinyin: "zhen de chou xiang")

print("=== 记录用户词后 ===")
show("mebengz"); show("woc"); show("zhedm"); show("buyaobuy"); show("gongn"); show("zhendchoux")
show("meibengzhu") // 全拼也应正常

print("=== kb27 校验 ===")
UserFreq.shared.record("的", pinyin: "d") // 脏键(缩写键)应被拒收
print("「的=d」脏键: " + (UserFreq.shared.hits(key: "d", partialPrefix: false).isEmpty ? "已拒收 ✓" : "污染 ✗"))
UserFreq.shared.record("来", pinyin: "lai")
UserFreq.shared.record("来", pinyin: "lai")
print("「来」单字乘数(打了2次): \(UserFreq.shared.boost("来")) (应=1.0,单字不吃词频乘数)")
show("zhendchoux") // 词组「真的抽象」逐音节宽松匹配(zhen✓ d⊂de chou✓ x⊂xiang)
