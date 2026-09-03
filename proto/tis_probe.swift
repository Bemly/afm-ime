import Carbon
import Foundation

func sources(_ filter: [String: Any]?, all: Bool) -> [TISInputSource] {
    let cf: CFDictionary? = filter.map { $0 as CFDictionary }
    return TISCreateInputSourceList(cf, all).takeRetainedValue() as? [TISInputSource] ?? []
}

func desc(_ src: TISInputSource) -> String {
    func get(_ key: CFString) -> String {
        guard let v = TISGetInputSourceProperty(src, key) else { return "?" }
        return (Unmanaged<CFString>.fromOpaque(v).takeUnretainedValue() as String)
    }
    return "id=\(get(kTISPropertyInputSourceID)) bundle=\(get(kTISPropertyBundleID)) name=\(get(kTISPropertyLocalizedName))"
}

let afmFilter = [kTISPropertyBundleID as String: "com.afm.AFMInput"]
print("== 全部已安装(含未启用)中 bundle=com.afm.AFMInput ==")
for s in sources(afmFilter, all: true) { print("  \(desc(s))") }

print("== 全部已安装中 id 含 afm (大小写不敏感) ==")
for s in sources(nil, all: true) {
    let d = desc(s)
    if d.lowercased().contains("afm") { print("  \(d)") }
}

print("== 当前启用的全部输入源 ==")
for s in sources(nil, all: false) { print("  \(desc(s))") }
