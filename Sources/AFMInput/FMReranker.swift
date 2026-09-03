import Foundation
import FoundationModels

/// 端侧 FM 候选重排:根据上文语境把最合适的候选提到首位。
/// 设计:每次新建 session(创建仅 ~1ms,无 transcript 增长,延迟稳定 ~0.3s);
/// 失败/不可用一律静默返回 nil,绝不阻塞打字。
final class FMReranker {
    static let shared = FMReranker()
    private static let instructions = "你是中文输入法的候选排序引擎。根据上文语境和拼音,从候选列表中选出最符合语境的一个。只输出该候选的序号数字,禁止输出任何其他内容。"

    private var available: Bool {
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        return false
    }

    /// 返回 FM 选中的候选在入参 candidates 中的下标;不可用/失败/无法解析返回 nil
    func rerank(context: String, pinyin: String, candidates: [String]) async -> Int? {
        guard available, !candidates.isEmpty else { return nil }
        let numbered = candidates.enumerated()
            .map { "\($0.offset + 1).\($0.element)" }
            .joined(separator: " ")
        let prompt = """
        上文:\(context.isEmpty ? "(句首)" : context)
        拼音:\(pinyin)
        候选:\(numbered)
        """
        guard #available(macOS 26.0, *) else { return nil }
        do {
            let session = LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: Self.instructions)
            let resp = try await session.respond(to: prompt)
            return Self.firstIndex(in: resp.content, upperBound: candidates.count)
        } catch {
            NSLog("[AFM][FM] rerank 失败: \(error)")
            return nil
        }
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
