import Foundation

/// 模型配置(kb36):端侧 FM 提示词可整段覆盖 + 云端模型切换(经 FoundationModels 官方 Provider
/// 协议接入,请求结构仍走框架 transcript,executor 只做线格式转换)。
/// 由 AFM拼音.app「模型」页写入 IME 域 defaults,引擎/helper 进程现读现判(每次 FM 调用读一次,
/// 非热循环)。键名以本文件常量为唯一来源,AFMApp 直接引用常量——不再两边逐字维护。
public enum ModelPrefs {
    // —— 云端模型 ——
    public static let cloudEnabledKey = "AFMCloudEnabled"
    public static let cloudProviderKey = "AFMCloudProvider"   // 预设 id(仅设置中心记忆用)
    public static let cloudBaseURLKey = "AFMCloudBaseURL"     // 接口前缀,如 https://api.deepseek.com/v1
    public static let cloudAPIKeyKey = "AFMCloudAPIKey"       // 明文本机存储(IME 域 defaults)
    public static let cloudModelKey = "AFMCloudModel"         // 模型名,如 deepseek-chat
    public static let cloudFormatKey = "AFMCloudFormat"       // 线格式:"openai" | "anthropic"

    // —— 端侧 FM 提示词覆盖(留空 = FMReranker 内置默认;云端启用时同样作为 instructions 生效)——
    public static let promptRerankKey = "AFMFMPromptRerank"
    public static let promptSentenceKey = "AFMFMPromptSentence"
    public static let promptTranslateENKey = "AFMFMPromptTranslateEN" // 中文→英
    public static let promptTranslateZHKey = "AFMFMPromptTranslateZH" // 外文→中

    public static var cloudEnabled: Bool {
        UserDefaults.standard.object(forKey: cloudEnabledKey) as? Bool ?? false
    }

    /// 云端线格式:"openai"(Chat Completions)| "anthropic"(Messages);未知值回退 openai
    public static var cloudFormat: String {
        let f = UserDefaults.standard.string(forKey: cloudFormatKey) ?? "openai"
        return f == "anthropic" ? "anthropic" : "openai"
    }

    /// 提示词覆盖:未设置或空白 → nil(用内置默认)
    public static func promptOverride(_ key: String) -> String? {
        guard let s = UserDefaults.standard.string(forKey: key),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}
