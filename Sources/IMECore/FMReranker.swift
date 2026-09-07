import Foundation
import FoundationModels

/// 端侧 FM 候选重排:根据上文语境把最合适的候选提到首位。
/// 设计:每次新建 session(创建仅 ~1ms,无 transcript 增长,延迟稳定 ~0.3s);
/// 失败/不可用一律静默返回 nil,绝不阻塞打字。
/// kb36:提示词可经设置中心「模型」页整段覆盖(留空用内置默认);云端模型启用时经
/// FoundationModels Provider 协议(CloudProviderModel)走同一 LanguageModelSession 代码路径,
/// 失败自动回落端侧 FM,端侧也不可用 → nil → 纯词典。
public final class FMReranker {
    public static let shared = FMReranker()

    // MARK: 内置默认提示词(「模型」页四段编辑框留空即用这些;改动请保留"只输出结果"约束,否则解析回退)

    public static let defaultRerankInstructions = "你是中文输入法的候选排序引擎。根据上文语境和拼音,从候选列表中选出最符合语境的一个。只输出该候选的序号数字,禁止输出任何其他内容。"
    public static let defaultSentenceInstructions = "你是中文拼音输入法的整句预测引擎。把用户输入的拼音串转成最通顺的中文。只输出中文结果,禁止解释、禁止重复拼音。"
    public static let defaultTranslateENInstructions = "你是翻译引擎。把用户输入的中文翻译成地道的英文。只输出译文,不要解释、不要加引号。"
    public static let defaultTranslateZHInstructions = "你是翻译引擎。把用户输入的外文翻译成通顺的简体中文。只输出译文,不要解释、不要加引号。"

    /// 提示词解析顺序:设置中心覆盖 → 内置默认(每次调用现读,cfprefsd 跨进程失效即时生效)
    private static var rerankInstructions: String {
        ModelPrefs.promptOverride(ModelPrefs.promptRerankKey) ?? defaultRerankInstructions
    }
    private static var sentenceInstructions: String {
        ModelPrefs.promptOverride(ModelPrefs.promptSentenceKey) ?? defaultSentenceInstructions
    }

    private var available: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// 统一出入口:云端启用且配置完整 → 云端(Provider 协议);失败/未启用/配置不全 → 端侧 FM;
    /// 都失败 → nil。label 仅用于日志区分(重排/整句/翻译)。
    private func respond(label: String, instructions: String, prompt: String) async -> String? {
        if ModelPrefs.cloudEnabled, let cfg = CloudProviderModel.configured() {
            let t0 = Date()
            do {
                let session = LanguageModelSession(model: CloudProviderModel(config: cfg),
                                                   instructions: instructions)
                let resp = try await session.respond(to: prompt)
                let ms = String(format: "%.0f", -t0.timeIntervalSinceNow * 1000)
                DebugLog.log("云端响应[\(label)](\(ms)ms, \(cfg.modelName)): '\(resp.content.prefix(40))'")
                return resp.content
            } catch {
                let ms = String(format: "%.0f", -t0.timeIntervalSinceNow * 1000)
                DebugLog.error("云端[\(label)]失败(\(ms)ms) → 回落端侧 FM: \(error)")
            }
        }
        guard available else {
            DebugLog.log("FM 不可用 available=false [\(label)](云端未启用或已回落)")
            return nil
        }
        let t0 = Date()
        do {
            let session = LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: instructions)
            let resp = try await session.respond(to: prompt)
            let ms = String(format: "%.0f", -t0.timeIntervalSinceNow * 1000)
            DebugLog.log("FM 响应[\(label)](\(ms)ms): '\(resp.content.prefix(40))'")
            return resp.content
        } catch {
            DebugLog.error("FM [\(label)]失败: \(error) (耗时\(String(format: "%.0f", -t0.timeIntervalSinceNow * 1000))ms)")
            return nil
        }
    }

    /// 返回 FM 选中的候选在入参 candidates 中的下标;不可用/失败/无法解析返回 nil
    public func rerank(context: String, pinyin: String, candidates: [String]) async -> Int? {
        guard !candidates.isEmpty else {
            DebugLog.log("FM 重排跳过: 无候选")
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
        guard let out = await respond(label: "重排", instructions: Self.rerankInstructions, prompt: prompt) else {
            return nil
        }
        let idx = Self.firstIndex(in: out, upperBound: candidates.count)
        DebugLog.log("FM 解析: idx=\(idx.map(String.init) ?? "nil")")
        return idx
    }

    /// FM 整句预测:长拼音词典覆盖不住时,直接让模型出句子
    public func predictSentence(context: String, pinyin: String) async -> String? {
        guard pinyin.count >= 4 else {
            DebugLog.log("FM 整句跳过: 长度=\(pinyin.count)")
            return nil
        }
        let prompt = """
        \(context.isEmpty ? "" : "上文:\(context)\n")拼音:\(pinyin)
        把拼音转成中文,只输出中文本身,不要解释。
        """
        DebugLog.log("FM 整句请求: 拼音='\(pinyin)' 上文='\(context)'")
        guard let out = await respond(label: "整句", instructions: Self.sentenceInstructions, prompt: prompt) else {
            return nil
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeChinese(trimmed) else {
            DebugLog.log("FM 整句拒绝: 不像中文输出")
            return nil
        }
        return trimmed
    }

    static func looksLikeChinese(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 60 else { return false }
        let cjk = s.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        return Double(cjk) >= Double(s.unicodeScalars.count) * 0.5
    }

    /// FM 翻译(⌃F 面板): 含中文 → 译英,否则 → 译中;失败/不可用静默 nil
    public func translate(_ text: String) async -> String? {
        guard !text.isEmpty else {
            DebugLog.log("FM 翻译跳过: 空输入")
            return nil
        }
        let toEnglish = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let instructions = toEnglish
            ? (ModelPrefs.promptOverride(ModelPrefs.promptTranslateENKey) ?? Self.defaultTranslateENInstructions)
            : (ModelPrefs.promptOverride(ModelPrefs.promptTranslateZHKey) ?? Self.defaultTranslateZHInstructions)
        guard let out = await respond(label: toEnglish ? "翻译中→英" : "翻译→中",
                                      instructions: instructions, prompt: text) else {
            return nil
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != text else { return nil }
        return trimmed
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
