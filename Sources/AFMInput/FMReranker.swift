import Foundation
import FoundationModels
import IMECore

/// 端侧 FM 候选重排:根据上文语境把最合适的候选提到首位。
/// 设计:每次新建 session(创建仅 ~1ms,无 transcript 增长,延迟稳定 ~0.3s);
/// 失败/不可用一律静默返回 nil,绝不阻塞打字。
final class FMReranker {
    static let shared = FMReranker()
    private static let instructions = "你是中文输入法的候选排序引擎。根据上文语境和拼音,从候选列表中选出最符合语境的一个。只输出该候选的序号数字,禁止输出任何其他内容。"
    private static let sentenceInstructions = "你是中文拼音输入法的整句预测引擎。把用户输入的拼音串转成最通顺的中文。只输出中文结果,禁止解释、禁止重复拼音。"

    private var available: Bool {
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        return false
    }

    /// 返回 FM 选中的候选在入参 candidates 中的下标;不可用/失败/无法解析返回 nil
    func rerank(context: String, pinyin: String, candidates: [String]) async -> Int? {
        guard available, !candidates.isEmpty else {
            DebugLog.log("FM 不可用或无候选 available=\(available)")
            return nil
        }
        let numbered = candidates.enumerated()
            .map { "\($0.offset + 1).\($0.element)" }
            .joined(separator: " ")
        let prompt = """
        上文:\(context.isEmpty ? "(句首)" : context)
        拼音:\(pinyin)
        候选:\(numbered)
        """
        DebugLog.log("FM 请求: \(prompt.replacingOccurrences(of: "\n", with: " | "))")
        guard #available(macOS 26.0, *) else { return nil }
        let t0 = Date()
        do {
            let session = LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: Self.instructions)
            let resp = try await session.respond(to: prompt)
            let ms = String(format: "%.0f", -t0.timeIntervalSinceNow * 1000)
            DebugLog.log("FM 响应(\(ms)ms): '\(resp.content)'")
            let idx = Self.firstIndex(in: resp.content, upperBound: candidates.count)
            DebugLog.log("FM 解析: idx=\(idx.map(String.init) ?? "nil")")
            return idx
        } catch {
            DebugLog.error("FM rerank 失败: \(error) (耗时\(String(format: "%.0f", -t0.timeIntervalSinceNow * 1000))ms)")
            return nil
        }
    }

    /// FM 整句预测:长拼音词典覆盖不住时,直接让模型出句子
    func predictSentence(context: String, pinyin: String) async -> String? {
        guard available, pinyin.count >= 4 else {
            DebugLog.log("FM 整句跳过: available=\(available) 长度=\(pinyin.count)")
            return nil
        }
        let prompt = """
        \(context.isEmpty ? "" : "上文:\(context)\n")拼音:\(pinyin)
        把拼音转成中文,只输出中文本身,不要解释。
        """
        DebugLog.log("FM 整句请求: 拼音='\(pinyin)' 上文='\(context)'")
        guard #available(macOS 26.0, *) else { return nil }
        let t0 = Date()
        do {
            let session = LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: Self.sentenceInstructions)
            let resp = try await session.respond(to: prompt)
            let ms = String(format: "%.0f", -t0.timeIntervalSinceNow * 1000)
            let out = resp.content.trimmingCharacters(in: .whitespacesAndNewlines)
            DebugLog.log("FM 整句响应(\(ms)ms): '\(out)'")
            guard Self.looksLikeChinese(out) else {
                DebugLog.log("FM 整句拒绝: 不像中文输出")
                return nil
            }
            return out
        } catch {
            DebugLog.error("FM 整句失败: \(error) (耗时\(String(format: "%.0f", -t0.timeIntervalSinceNow * 1000))ms)")
            return nil
        }
    }

    static func looksLikeChinese(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 60 else { return false }
        let cjk = s.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        return Double(cjk) >= Double(s.unicodeScalars.count) * 0.5
    }

    static func firstIndex(in text: String, upperBound: Int) -> Int? {
        var digits = ""
        for ch in text {
            if ch.isNumber { digits.append(ch) }
            else if !digits.isEmpty { break }
        }
        guard let n = Int(digits), (1...upperBound).contains(n) else { return nil }
        return n - 1
    }
}
