import AppKit
import Carbon
import Foundation

/// 输入法安装/启用/选中(TIS 三连 + defaults 兜底),供输入法 CLI 与安装器 App 共用。
/// 经验结论(macOS 27 实测):
/// - TISRegisterInputSource:瞬态注册,持久化靠登录扫描;**对已注册的 bundle 重复调用会多出灰色源实例,必须查重**
/// - TISEnableInputSource:对 ad-hoc 包返回 noErr 但不落盘 → 需 defaults 直写启用列表
/// - TISSelectInputSource:干净状态下可用;脏状态返回 -50
/// - 卸载必须先 TISDisableInputSource 停用全部实例,否则 TIS 回写会把启用条目带回来
public enum IMEInstaller {
    public static let bundleID = "moe.bemly.inputmethod.AfmIME"
    public static let modeID = "moe.bemly.inputmethod.AfmIME.Hans"
    /// 历史遗留 id(清理用)
    public static let legacyBundleIDs: Set<String> = [
        "com.afm.inputmethod.afmpinyin", "com.afm.inputmethod.afmpinyin.hans",
        "com.afm.AFMInput", "com.afm.AFMInput.hans",
        "moe.bemly.inputmethod.ime", "moe.bemly.inputmethod.ime.hans",
        "moe.bemly.inputmethod", "moe.bemly.inputmethod.hans",
        "moe.bemly.inputmethod.afmpinyin", "moe.bemly.inputmethod.afmpinyin.hans",
    ]
    public static let imeAppName = "AFM拼音.app"
    public static let toolboxDomain = "com.apple.HIToolbox" as CFString

    // MARK: - 查询

    public static func allSources() -> [TISInputSource] {
        guard let unmanaged = TISCreateInputSourceList(nil, true) else { return [] }
        let arr = unmanaged.takeRetainedValue() as CFArray
        return (0..<CFArrayGetCount(arr)).map {
            unsafeBitCast(CFArrayGetValueAtIndex(arr, $0), to: TISInputSource.self)
        }
    }

    public static func enabledSources() -> [TISInputSource] {
        guard let unmanaged = TISCreateInputSourceList(nil, false) else { return [] }
        let arr = unmanaged.takeRetainedValue() as CFArray
        return (0..<CFArrayGetCount(arr)).map {
            unsafeBitCast(CFArrayGetValueAtIndex(arr, $0), to: TISInputSource.self)
        }
    }

    public static func sourceWithID(_ id: String) -> TISInputSource? {
        allSources().first { strProp($0, kTISPropertyInputSourceID) == id }
    }

    /// 本输入法的全部源实例(含历史遗留 id;可能有重复注册产生的多份)
    public static func afmRefs() -> [TISInputSource] {
        allSources().filter {
            let id = strProp($0, kTISPropertyInputSourceID)
            return id == modeID || id == bundleID || legacyBundleIDs.contains(id)
        }
    }

    public static func strProp(_ src: TISInputSource, _ key: CFString) -> String {
        guard let v = TISGetInputSourceProperty(src, key) else { return "" }
        return Unmanaged<CFString>.fromOpaque(v).takeUnretainedValue() as String
    }

    /// TIS 启用视图中本输入法实例数
    public static func enabledRefCount() -> Int {
        enabledSources().filter { strProp($0, kTISPropertyInputSourceID) == modeID }.count
    }

    public static func isRegistered() -> Bool {
        sourceWithID(modeID) != nil
    }

    public static func installedIMEURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods/\(imeAppName)")
    }

    public static func isBundleInstalled() -> Bool {
        FileManager.default.fileExists(atPath: installedIMEURL().path)
    }

    /// 当前状态摘要(供 UI 显示)
    public static func statusSummary() -> String {
        let installed = isBundleInstalled()
        let registered = isRegistered()
        let refs = enabledRefCount()
        if installed && registered && refs == 1 { return "✓ 已安装并启用 — 按 Ctrl+Space 切换后即可打字" }
        if installed && registered && refs > 1 { return "⚠︎ 已启用但存在 \(refs) 个重复实例 — 点「安装并启用输入法」收敛" }
        if installed && registered { return "已安装未启用 — 点「安装并启用输入法」" }
        if installed { return "已安装,等待 TIS 收录 — 请注销并重新登录一次" }
        if registered { return "输入源已注册,app 未安装 — 点「安装并启用输入法」" }
        return "未安装 — 点「安装并启用输入法」"
    }

    // MARK: - 动作

    @discardableResult
    public static func register(bundleURL: URL) -> (status: OSStatus, skipped: Bool) {
        if isRegistered() {
            return (noErr, true) // 已注册,重复调用会产生多余灰色实例
        }
        return (TISRegisterInputSource(bundleURL as CFURL), false)
    }

    /// 等待条件成立(TIS 状态异步传播,立即查询会误报)
    static func waitUpTo(_ seconds: Double, interval: Double = 0.3, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if cond() { return true }
            usleep(useconds_t(interval * 1_000_000))
        }
        return cond()
    }

    /// 安装:拷贝 IME bundle 到 ~/Library/Input Methods 并注册(查重)
    public static func install(embeddedIMEURL: URL) -> String {
        var log = ""
        let fm = FileManager.default
        let dest = installedIMEURL()
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: embeddedIMEURL, to: dest)
            log += "✓ 已拷贝到 ~/Library/Input Methods\n"
        } catch {
            return log + "✗ 拷贝失败: \(error.localizedDescription)\n"
        }
        let r = register(bundleURL: dest)
        if r.skipped {
            log += "✓ TIS 已注册过(跳过重复注册)\n"
        } else {
            log += "TISRegisterInputSource = \(r.status)\n"
            if waitUpTo(5) { isRegistered() } {
                log += "✓ TIS 已可见\n"
            } else {
                log += "⚠︎ TIS 暂不可见 — 首次安装请注销并重新登录一次(登录扫描收录后,以后无需再注销)\n"
            }
        }
        return log
    }

    /// 停用本输入法的全部 TIS 实例(卸载/收敛前必须做,否则 TIS 回写复活条目)
    @discardableResult
    public static func disableAll() -> String {
        var log = ""
        for src in afmRefs() {
            let id = strProp(src, kTISPropertyInputSourceID)
            let st = TISDisableInputSource(src)
            if st != noErr { log += "TISDisable(\(id)) = \(st)\n" }
        }
        return log
    }

    /// 启用:收敛到单实例 → TIS API → 验证 → defaults 兜底 → 启用列表精确化
    @discardableResult
    public static func enable() -> (ok: Bool, log: String) {
        var log = disableAll()
        guard let src = sourceWithID(modeID) else {
            let ok = writeEnabledEntries()
            log += ok ? "✓ defaults 启用写入成功(输入源未注册)\n" : "✗ 输入源未注册,defaults 兜底也失败\n"
            return (ok, log)
        }
        let st = TISEnableInputSource(src)
        log += "TISEnableInputSource = \(st)\n"
        let viewOK = waitUpTo(3) { self.enabledRefCount() == 1 }
        if viewOK {
            log += "✓ TIS 启用视图:单实例\n"
        } else {
            log += "TIS 启用未落盘/存在多实例 → defaults 直写收敛\n"
        }
        let ok = writeEnabledEntries()
        log += ok ? "✓ 启用列表已收敛为 1 条\n" : "✗ defaults 写入失败\n"
        return (ok, log)
    }

    /// defaults 直写 com.apple.HIToolbox 启用列表:清掉自家(含遗留 id)全部条目后只写一条 mode
    @discardableResult
    public static func writeEnabledEntries() -> Bool {
        let allOwnIDs = legacyBundleIDs.union([bundleID])
        var existing: [[String: Any]] = []
        if let raw = CFPreferencesCopyAppValue("AppleEnabledInputSources" as CFString, toolboxDomain),
           let list = (raw as? NSArray) as? [[String: Any]] {
            existing = list
        }
        let others = existing.filter { !allOwnIDs.contains(($0["Bundle ID"] as? String) ?? "") }
        // 与系统输入法(SCIM)一致:base(Keyboard Input Method)+ mode(Input Mode)各一条
        // 编辑器靠 base 渲染标题,mode 才是可切换的输入源;缺 base 会只剩描述没有标题
        let modeEntry: [String: Any] = [
            "Bundle ID": bundleID,
            "Input Mode": modeID,
            "InputSourceKind": "Input Mode",
        ]
        let baseEntry: [String: Any] = [
            "Bundle ID": bundleID,
            "InputSourceKind": "Keyboard Input Method",
        ]
        let next = others + [modeEntry, baseEntry]
        CFPreferencesSetAppValue("AppleEnabledInputSources" as CFString, next as CFArray, toolboxDomain)
        CFPreferencesAppSynchronize(toolboxDomain)
        return enabledRefCount() == 1
    }

    @discardableResult
    public static func select() -> (ok: Bool, log: String) {
        guard let src = sourceWithID(modeID) else {
            return (false, "✗ TIS 中未找到 \(modeID)\n")
        }
        let st = TISSelectInputSource(src)
        return (st == noErr, "TISSelectInputSource = \(st)\(st == noErr ? "(成功)" : "(失败,用菜单栏或 Ctrl+Space 切换即可)")\n")
    }

    /// 卸载:停用全部实例 → 删 bundle → defaults 清条目
    @discardableResult
    public static func uninstall() -> String {
        var log = disableAll()
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
        let fm = FileManager.default
        for path in [installedIMEURL().path, "/Library/Input Methods/\(imeAppName)"] {
            if fm.fileExists(atPath: path) {
                do { try fm.removeItem(atPath: path); log += "✓ 已删除 \(path)\n" }
                catch { log += "✗ 删除 \(path) 失败(系统目录需要 sudo)\n" }
            }
        }
        cleanDefaults()
        log += "✓ defaults 启用条目已清理\n"
        return log
    }

    static func cleanDefaults() {
        let allIDs = legacyBundleIDs.union([bundleID])
        for key in ["AppleEnabledInputSources", "AppleSelectedInputSources", "AppleInputSourceHistory"] as [CFString] {
            guard let raw = CFPreferencesCopyAppValue(key, toolboxDomain),
                  let list = (raw as? NSArray) as? [[String: Any]] else { continue }
            let filtered = list.filter { entry in
                let bid = entry["Bundle ID"] as? String
                let mode = entry["Input Mode"] as? String
                return !(allIDs.contains(bid ?? "") || allIDs.contains(mode ?? ""))
            }
            if filtered.count != list.count {
                CFPreferencesSetAppValue(key, filtered as CFArray, toolboxDomain)
            }
        }
        CFPreferencesAppSynchronize(toolboxDomain)
    }
}
