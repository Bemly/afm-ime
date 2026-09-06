import Foundation

/// 用户设置:由 AFM拼音.app(GUI) 写入 IME 域(moe.bemly.inputmethod.AfmIME,即本进程的
/// UserDefaults.standard 域),输入法侧现读现判——每次按键/查询时重新求值,cfprefsd 的跨进程
/// 失效保证外部改动即时生效。键名与 AFMApp 设置页逐字一致——两边都要改。
public enum UserPrefs {
    private static func bool(_ key: String, default def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? def
    }

    /// 英文直通模式(Shift 轻点与设置面板均可切;InputController 另有 AFMEnglishMode 直读写,语义一致)
    public static var englishMode: Bool { bool("AFMEnglishMode", default: false) }
    /// 模糊拼音 zh/z、ch/c、sh/s + 前后鼻音(默认开;关 = 只认精确拼音)
    public static var fuzzyPinyin: Bool { bool("AFMFuzzyPinyin", default: true) }
    /// 中文模式全角标点映射(默认开;关 = 标点半角原样直通)
    public static var fullWidthPunct: Bool { bool("AFMFullWidthPunct", default: true) }
    /// FM 增强:候选重排 + 整句预测(默认开;关 = 纯词典,不占位不转圈)
    public static var fmEnhance: Bool { bool("AFMFMEnhance", default: true) }
    /// 用户词频乘法 + 用户词库最高档(默认开;关 = 词典权重原样,学习数据保留)
    public static var userFreq: Bool { bool("AFMUserFreqEnabled", default: true) }

    /// 候选条字号(13-22,默认 16;仅条态生效——网格几何钉死 28/29,字号动它会破坏滚动闭合)
    public static var candidateFontSize: Int {
        UserDefaults.standard.object(forKey: "AFMCandidateFontSize") as? Int ?? 16
    }
}
