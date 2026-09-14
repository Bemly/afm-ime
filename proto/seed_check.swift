import IMECore
import Foundation

// builtin-user-words.json 内置词种子验证(kb40): 补缺/不覆盖本机/幂等/删除不复活/版本升级补种。
// 跑法(同 userdict_check):
//   swift build --target IMECore
//   swiftc proto/seed_check.swift $(find .build/out/Intermediates.noindex/afm-ime.build/Debug/IMECore-t.build/Objects-normal/arm64 -name '*.o') \
//     -o proto/seed_check -I .build/out/Products/Debug -framework FoundationModels

let suiteName = "afm.seedcheck.tmp"
UserDefaults().removePersistentDomain(forName: suiteName)
let d = UserDefaults(suiteName: suiteName)!

// 种子文件: v1 = 新词A / 本机已有B(本地次数更高,应保本地) / 本机已有C(种子次数更高,应取种子) /
// D 拼音非法(只进词频不进用户词库)
let fixture = URL(fileURLWithPath: "/tmp/afm-seed-fixture.json")
let json = """
{"version": 1, "words": [
  {"word": "种子新词", "pinyin": "zhong zi xin ci", "count": 3},
  {"word": "本地高频", "pinyin": "ben di gao pin", "count": 100},
  {"word": "种子高频", "pinyin": "zhong zi gao pin", "count": 88},
  {"word": "脏键词", "pinyin": "zang jian g", "count": 5},
  {"word": "", "pinyin": "kong ci", "count": 5}
]}
"""
try! json.data(using: .utf8)!.write(to: fixture)
d.set(["本地高频": 500, "种子高频": 10], forKey: "AFMUserFreq")
d.set(["本地高频": "ben di gao pin", "种子高频": "zhong zi gao pin"], forKey: "AFMUserPinyin")

func counts() -> [String: Int] { d.dictionary(forKey: "AFMUserFreq") as? [String: Int] ?? [:] }
func pins() -> [String: String] { d.dictionary(forKey: "AFMUserPinyin") as? [String: String] ?? [:] }
func check(_ name: String, _ ok: Bool) { print("\(ok ? "✓" : "✗ 失败") \(name)") }

// ① 首次补种
let uf1 = UserFreq(defaults: d, builtinWordsURL: fixture)
check("新词补入(种子新词=3)", counts()["种子新词"] == 3)
check("本机高频不被覆盖(本地高频=500)", counts()["本地高频"] == 500)
check("种子高频取较大者(=88)", counts()["种子高频"] == 88)
check("脏键拼音不进用户词库", pins()["脏键词"] == nil && counts()["脏键词"] == 5)
check("空词被跳过", counts()[""] == nil)
check("版本标记 v1", d.integer(forKey: "AFMBuiltinUserWordsSeeded") == 1)

// ② 幂等: 重建实例不再变动
d.set(["本地高频": 499], forKey: "AFMUserFreq") // 模拟本机次数回落
_ = UserFreq(defaults: d, builtinWordsURL: fixture)
check("幂等(重建后仍=499)", counts()["本地高频"] == 499)

// ③ 删除不复活: 走设置中心同款路径(删 counts + 记墓碑)再重建
var c = counts(); c.removeValue(forKey: "种子新词"); d.set(c, forKey: "AFMUserFreq")
UserFreq.tombstone(words: ["种子新词"], defaults: d)
_ = UserFreq(defaults: d, builtinWordsURL: fixture)
check("删除的种子词不复活", counts()["种子新词"] == nil)

// ④ 版本升级: v2 补新词、旧词不动、墓碑词继续被挡
let json2 = """
{"version": 2, "words": [
  {"word": "种子新词", "pinyin": "zhong zi xin ci", "count": 3},
  {"word": "二期新词", "pinyin": "er qi xin ci", "count": 7}
]}
"""
try! json2.data(using: .utf8)!.write(to: fixture)
_ = UserFreq(defaults: d, builtinWordsURL: fixture)
check("v2 补种二期新词", counts()["二期新词"] == 7)
check("v2 墓碑词仍不复活", counts()["种子新词"] == nil)
check("v2 标记更新", d.integer(forKey: "AFMBuiltinUserWordsSeeded") == 2)

// ⑤ 导入解除墓碑(显式带回=用户改主意): 下一版本种子重新可用
UserFreq.untombstone(words: ["种子新词"], defaults: d)
let json3 = """
{"version": 3, "words": [
  {"word": "种子新词", "pinyin": "zhong zi xin ci", "count": 3}
]}
"""
try! json3.data(using: .utf8)!.write(to: fixture)
_ = UserFreq(defaults: d, builtinWordsURL: fixture)
check("解除墓碑后 v3 重新补入(=3)", counts()["种子新词"] == 3)
check("v3 标记更新", d.integer(forKey: "AFMBuiltinUserWordsSeeded") == 3)

UserDefaults().removePersistentDomain(forName: suiteName)
try? FileManager.default.removeItem(at: fixture)
print("=== seed_check 完 ===")
