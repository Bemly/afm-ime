// AFM拼音 设置面板(Preferences.prefPane): 系统设置 → 键盘 → 输入法 → AFM拼音 详情页选项区。
// 机制: KeyboardSettings.appex 按约定路径加载输入法 bundle Resources 里的 Preferences.prefPane,
// 实例化 NSPrincipalClass 并嵌入隐私文案下方(SCIM/PluginIM 同款,见 AGENTS.md 决策记录)。
// 程序化搭视图(无 nib);设置写 CFPreferences 域 moe.bemly.inputmethod.AfmIME
// (= IME 进程的 UserDefaults.standard 域),输入法侧现读现判即时生效。
// 键名与 IMECore/UserPrefs.swift 的属性必须逐字一致。
import AppKit
import PreferencePanes

private let prefsDomain = "moe.bemly.inputmethod.AfmIME" as CFString

@objc(AFMPrefsPane)
final class AFMPrefsPane: NSPreferencePane {
    /// (defaults 键, 标题, 说明, 默认开) —— 键名与 IMECore/UserPrefs.swift 一一对应
    private let rows: [(key: String, title: String, desc: String, defaultOn: Bool)] = [
        ("AFMEnglishMode", "英文模式",
         "英文直通,无候选框、标点半角;轻点 Shift 随时切换", false),
        ("AFMFuzzyPinyin", "模糊拼音",
         "zh/z、ch/c、sh/s 与 an/ang、en/eng、in/ing 互通,精确拼音候选始终优先", true),
        ("AFMFullWidthPunct", "全角标点",
         "中文模式下 ,.;:?! 等自动上屏全角,引号成对交替;关闭后原样半角直通", true),
        ("AFMFMEnhance", "FM 增强",
         "端侧 Apple 模型对候选重排与整句预测(异步约 0.3 秒到达,不阻塞打字)", true),
        ("AFMUserFreqEnabled", "记住打过的词",
         "选用过的词进用户词库最高档直出,并随使用次数加权", true),
    ]
    private var toggles: [NSSwitch] = []

    override func loadMainView() -> NSView {
        var switches: [NSSwitch] = []
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)

        for row in rows {
            let sw = NSSwitch()
            sw.controlSize = .regular
            sw.state = prefBool(row.key, default: row.defaultOn) ? .on : .off
            sw.target = self
            sw.action = #selector(toggleChanged(_:))
            sw.identifier = NSUserInterfaceItemIdentifier(row.key)

            let title = NSTextField(labelWithString: row.title)
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            let desc = NSTextField(wrappingLabelWithString: row.desc)
            desc.font = .systemFont(ofSize: 11)
            desc.textColor = .secondaryLabelColor
            desc.preferredMaxLayoutWidth = 360

            let textCol = NSStackView(views: [title, desc])
            textCol.orientation = .vertical
            textCol.alignment = .leading
            textCol.spacing = 2

            let rowView = NSStackView(views: [sw, textCol])
            rowView.orientation = .horizontal
            rowView.alignment = .centerY
            rowView.spacing = 10
            stack.addArrangedSubview(rowView)
            switches.append(sw)
        }
        toggles = switches

        let version = Bundle(for: Self.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let footer = NSTextField(
            wrappingLabelWithString: "AFM拼音 \(version) · 设置即时生效(输入法每次按键现读)")
        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .tertiaryLabelColor
        footer.preferredMaxLayoutWidth = 430
        stack.addArrangedSubview(footer)

        let width: CGFloat = 470
        stack.setFrameSize(NSSize(width: width, height: stack.fittingSize.height))
        stack.layoutSubtreeIfNeeded() // 宿主可能直接取 frame 呈现,离开 loadMainView 前把 Auto Layout 解算完
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: stack.frame.height))
        stack.autoresizingMask = [.width]
        container.addSubview(stack)
        mainView = container
        initialKeyView = switches.first
        firstKeyView = switches.first
        lastKeyView = switches.last
        return container
    }

    /// 每次面板被选中时同步开关(组词中 Shift 切换/外部 defaults 改动)
    override func didSelect() {
        for (i, row) in rows.enumerated() where i < toggles.count {
            toggles[i].state = prefBool(row.key, default: row.defaultOn) ? .on : .off
        }
    }

    @objc private func toggleChanged(_ sender: NSSwitch) {
        guard let key = sender.identifier?.rawValue else { return }
        let on = sender.state == .on
        CFPreferencesSetAppValue(key as CFString, on ? kCFBooleanTrue : kCFBooleanFalse, prefsDomain)
        CFPreferencesAppSynchronize(prefsDomain)
        NSLog("[AFMPrefs] 设置 \(key) = \(on)")
    }

    private func prefBool(_ key: String, default def: Bool) -> Bool {
        guard let v = CFPreferencesCopyAppValue(key as CFString, prefsDomain) else { return def }
        return (v as? NSNumber)?.boolValue ?? def
    }
}
