import Foundation
import IMECore

let store = try DictStore(url: URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Data/dict.bin"))
let queries = CommandLine.arguments.count > 2 ? Array(CommandLine.arguments.dropFirst(2)) : ["ni hao", "ni h", "jin tian"]
for p in queries {
    let hits = store.query(prefix: p)
    print("[\(p)] -> \(hits.count) 条, 前3: " + hits.prefix(3).map { "\($0.word)|\($0.key)|\($0.weight)" }.joined(separator: " ; "))
}
