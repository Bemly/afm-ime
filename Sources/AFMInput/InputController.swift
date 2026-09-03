import AppKit
import InputMethodKit
import IMECore

// 注意: 不要写显式 @objc 名——Swift 自动以 Module.Class 暴露(afm_input.InputController),
// Info.plist 的 InputMethodServerControllerClass 必须与之一致(VietTelex 教训)。
final class InputController: IMKInputController {
    // MARK: - 引擎(进程内单例)

    static let engine: CandidateEngine? = {
        let path = Bundle.main.path(forResource: "dict", ofType: "bin") ?? "Data/dict.bin"
        guard let store = try? DictStore(url: URL(fileURLWithPath: path)) else {
            NSLog("[AFM] 词库加载失败: %@", path)
            return nil
        }
        NSLog("[AFM] 词库已加载 %@ (记录 %d)", path, store.recordCount)
        return CandidateEngine(store: store)
    }()

    private var raw = ""                    // 拼音缓冲
    private var candidates: [CandidateEngine.Candidate] = []
    private var candidateWindow: IMKCandidates?

    // MARK: - 生命周期

    override init(server: IMKServer!, delegate: Any!, client: Any!) {
        super.init(server: server, delegate: delegate, client: client)
    }

    override func activateServer(_ sender: Any!) {}
    override func deactivateServer(_ sender: Any!) {
        commitComposition(sender)
    }
    override func hidePalettes() {
        candidateWindow?.hide()
    }

    // MARK: - 按键处理

    override func handle(_ event: NSEvent!, client: Any!) -> Bool {
        guard Self.engine != nil else { return false }
        guard let event, event.type == .keyDown else { return false }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !mods.isSubset(of: [.shift, .capsLock]) { return false } // 含 cmd/ctrl/opt 一律放行

        guard let chars = event.charactersIgnoringModifiers, chars.count == 1,
              let scalar = chars.unicodeScalars.first else { return false }
        let key = Character(chars).lowercased().first ?? "_"

        switch true {
        case ("a"..."z").contains(key), key == "'":
            raw.append(key)
            refresh(client)
            return true

        case scalar.value == 49 && !raw.isEmpty: // 空格
            commit(candidates.first?.text ?? raw, client: client)
            return true

        case scalar.value == 36 && !raw.isEmpty: // 回车: 上屏拼音原文
            commit(raw, client: client)
            return true

        case (49...57).contains(scalar.value) && !candidates.isEmpty: // 数字 1-9
            let idx = Int(scalar.value) - 49
            if idx < candidates.count {
                commit(candidates[idx].text, client: client)
                return true
            }
            return false

        case scalar.value == 51 && !raw.isEmpty: // 退格
            raw.removeLast()
            refresh(client)
            return true

        case scalar.value == 53 && !raw.isEmpty: // Esc 取消组词
            clearComposition(client)
            return true

        default:
            if !raw.isEmpty { // 标点等: 先上屏首选,标点放行
                commit(candidates.first?.text ?? raw, client: client)
                return false
            }
            return false
        }
    }

    // MARK: - 组词状态

    override func composedString(_ sender: Any!) -> Any! {
        NSAttributedString(string: raw)
    }

    override func originalString(_ sender: Any!) -> NSAttributedString! {
        NSAttributedString(string: raw)
    }

    override func candidates(_ sender: Any!) -> [Any]! {
        candidates.map { NSAttributedString(string: $0.text) }
    }

    override func candidateSelected(_ candidateString: NSAttributedString!) {
        guard let s = candidateString?.string else { return }
        commit(s, client: client())
    }

    override func candidateSelectionChanged(_ candidateString: NSAttributedString!) {}

    override func commitComposition(_ sender: Any!) {
        guard !raw.isEmpty else { return }
        commit(candidates.first?.text ?? raw, client: sender)
    }

    // MARK: - 内部

    private func window(_ client: Any!) -> IMKCandidates? {
        if candidateWindow == nil, let srv = server(), let w = IMKCandidates(server: srv, panelType: 2) {
            w.setSelectionKeys((49...57).map { NSNumber(value: $0) })
            candidateWindow = w
        }
        return candidateWindow
    }

    private func refresh(_ client: Any!) {
        guard let textInput = client as? IMKTextInput else { return }
        candidates = raw.isEmpty ? [] : (Self.engine?.candidates(for: raw, limit: 30) ?? [])

        let marked = NSMutableAttributedString(string: raw)
        if !raw.isEmpty {
            marked.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue],
                                 range: NSRange(location: 0, length: raw.utf16.count))
        }
        textInput.setMarkedText(marked,
                                selectionRange: NSRange(location: marked.length, length: 0),
                                replacementRange: NSRange(location: NSNotFound, length: NSNotFound))

        if candidates.isEmpty {
            candidateWindow?.hide()
        } else {
            let w = window(client)
            w?.perform(NSSelectorFromString("updateCandidates"))
            w?.show(2) // 光标下方
        }
    }

    private func commit(_ text: String, client: Any!) {
        guard let textInput = client as? IMKTextInput else {
            clearComposition(client); return
        }
        textInput.insertText(NSAttributedString(string: text),
                             replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        clearComposition(client)
    }

    private func clearComposition(_ client: Any!) {
        raw = ""
        candidates = []
        if let textInput = client as? IMKTextInput {
            textInput.setMarkedText(NSMutableAttributedString(),
                                    selectionRange: NSRange(location: 0, length: 0),
                                    replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        }
        candidateWindow?.hide()
    }
}
