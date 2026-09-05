// 结构化输出对准确率影响的三通道对照实验 —— 案例: beng bu zhu le(蚌埠住了/绷不住了/蹦不住了)
// 通道1 free   : 自由文本回序号 + 客户端正则解析(线上 FMReranker 现状)
// 通道2 int    : respond(generating: Int.self) 裸整数 schema(无字段语义/取值范围)
// 通道3 anyOf  : GenerationSchema(type: String.self, anyOf: 候选) 枚举约束,只能三选一
// 注: CLT 无 FoundationModelsMacros 宏插件,故不使用 @Generable,全部走非宏 API。
import Foundation
import FoundationModels

@available(macOS 26.0, *)
enum Bench {
    static func firstIndex(in text: String, upperBound: Int) -> Int? {
        var digits = ""
        for ch in text {
            if ch.isNumber { digits.append(ch) }
            else if !digits.isEmpty { break }
        }
        guard let n = Int(digits), (1...upperBound).contains(n) else { return nil }
        return n - 1
    }

    static func run() async {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { print("模型不可用"); return }

        let rerankInstructions = "你是中文输入法的候选排序引擎。根据上文语境和拼音,从候选列表中选出最符合语境的一个。只输出该候选的序号数字,禁止输出任何其他内容。"
        let sentenceInstructions = "你是中文拼音输入法的整句预测引擎。把用户输入的拼音串转成最通顺的中文。只输出中文结果,禁止解释、禁止重复拼音。"

        let candidatesA = ["蚌埠住了", "绷不住了", "蹦不住了"]
        let candidatesB = ["绷不住了", "蚌埠住了", "蹦不住了"]
        let contexts = [
            ("搞笑语境", "这段子太绝了,我"),
            ("地名语境", "到安徽蚌埠旅游,我"),
            ("无上文",   ""),
        ]
        let rounds = 8

        func rerankPrompt(_ ctx: String, _ cands: [String]) -> String {
            let numbered = cands.enumerated().map { "\($0.offset + 1).\($0.element)" }.joined(separator: " ")
            return "上文:\(ctx.isEmpty ? "(句首)" : ctx)\n拼音:beng bu zhu le\n候选:\(numbered)"
        }

        print("========== 任务 A:三通道重排对照(每格 \(rounds) 次) ==========")
        for (label, ctx) in contexts {
            for (modeName, cands) in [("正序", candidatesA), ("反序", candidatesB)] {
                if label != "搞笑语境" && modeName == "反序" { continue }
                var freePick = [Int: Int](), intPick = [Int: Int](), anyPick = [Int: Int]()
                var freeFail = 0, intFail = 0, anyFail = 0
                var intBadVals = Set<Int>(); var failReasons = [String: Int]()
                var ms: [String: [Double]] = ["free": [], "int": [], "any": []]
                let schema = GenerationSchema(type: String.self, anyOf: cands)

                for r in 0..<rounds {
                    // 通道1 free
                    let s1 = LanguageModelSession(model: model, instructions: rerankInstructions)
                    let t1 = Date()
                    do {
                        let resp = try await s1.respond(to: rerankPrompt(ctx, cands))
                        ms["free"]!.append(-t1.timeIntervalSinceNow * 1000)
                        if let idx = firstIndex(in: resp.content, upperBound: cands.count) {
                            freePick[idx, default: 0] += 1
                        } else { freeFail += 1 }
                    } catch { freeFail += 1 }

                    // 通道2 int
                    let s2 = LanguageModelSession(model: model, instructions: rerankInstructions)
                    let t2 = Date()
                    do {
                        let resp = try await s2.respond(to: rerankPrompt(ctx, cands), generating: Int.self)
                        ms["int"]!.append(-t2.timeIntervalSinceNow * 1000)
                        if (1...cands.count).contains(resp.content) {
                            intPick[resp.content - 1, default: 0] += 1
                        } else { intFail += 1; intBadVals.insert(resp.content) }
                    } catch { intFail += 1; failReasons["int:\(type(of: error))", default: 0] += 1 }

                    // 通道3 anyOf
                    let s3 = LanguageModelSession(model: model, instructions: rerankInstructions)
                    let t3 = Date()
                    do {
                        let resp = try await s3.respond(to: rerankPrompt(ctx, cands), schema: schema)
                        ms["any"]!.append(-t3.timeIntervalSinceNow * 1000)
                        let w = try resp.content.value(String.self)
                        if let idx = cands.firstIndex(of: w) {
                            anyPick[idx, default: 0] += 1
                        } else { anyFail += 1 }
                    } catch { anyFail += 1; failReasons["any:\(type(of: error))", default: 0] += 1 }
                    _ = r
                }
                func dist(_ d: [Int: Int]) -> String {
                    (0..<cands.count).map { i in "\(cands[i]):\(d[i] ?? 0)" }.joined(separator: "/")
                }
                func p50(_ a: [Double]) -> String { a.isEmpty ? "-" : String(format: "%.0fms", a.sorted()[a.count/2]) }
                print("【\(label)·\(modeName)】")
                print("  free 自由文本: \(dist(freePick))  失败:\(freeFail)  P50=\(p50(ms["free"]!))")
                print("  int 裸整数  : \(dist(intPick))  失败:\(intFail)\(intBadVals.isEmpty ? "" : " 越界值:\(intBadVals.sorted())")  P50=\(p50(ms["int"]!))")
                print("  any枚举约束 : \(dist(anyPick))  失败:\(anyFail)  P50=\(p50(ms["any"]!))")
                if !failReasons.isEmpty { print("  失败类型: \(failReasons.map { "\($0.key)×\($0.value)" }.joined(separator: " "))") }
            }
        }

        // MARK: - 任务 B: 整句转写
        print("\n========== 任务 B:整句转写 beng bu zhu le(每格 \(rounds) 次) ==========")
        for (label, ctx) in contexts {
            var outputs = [String: Int]()
            for _ in 0..<rounds {
                let s = LanguageModelSession(model: model, instructions: sentenceInstructions)
                let prompt = "\(ctx.isEmpty ? "" : "上文(仅供理解,严禁原样输出):\(ctx)\n")拼音:beng bu zhu le\n只输出该拼音对应的中文本身,不要输出上文、不要解释。"
                do {
                    let resp = try await s.respond(to: prompt)
                    outputs[resp.content.trimmingCharacters(in: .whitespacesAndNewlines), default: 0] += 1
                } catch {}
            }
            print("【\(label)】 \(outputs.map { "\($0.key)×\($0.value)" }.joined(separator: " / "))")
        }
        print("\n完成。")
    }
}

if #available(macOS 26.0, *) {
    let sem = DispatchSemaphore(value: 0)
    Task { defer { sem.signal() }; await Bench.run() }
    sem.wait()
} else { print("需要 macOS 26+") }
