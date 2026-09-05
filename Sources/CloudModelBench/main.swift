// 云端大模型接入实验:同一套 OpenAI Chat Completions 协议下的三通道对照
//  通道1 fm-inproc : 进程内 SystemLanguageModel(输入法现状,零网络)
//  通道2 fm-serve  : 自动拉起 `fm serve`,用 URLSession 经 HTTP 调本地 FM(证明协议互通)
//  通道3 cloud     : 任意 OpenAI 兼容云端,配置走环境变量(未配置则跳过):
//      export CLOUD_BASE_URL=https://api.deepseek.com/v1      # 或 OpenAI/豆包方舟/通义/Ollama
//      export CLOUD_API_KEY=sk-xxxx
//      export CLOUD_MODEL=deepseek-chat
//  兼容端点示例(baseURL / model):
//      OpenAI   https://api.openai.com/v1                 gpt-4o-mini
//      DeepSeek https://api.deepseek.com/v1               deepseek-chat
//      豆包方舟 https://ark.cn-beijing.volces.com/api/v3   <推理接入点id>
//      通义     https://dashscope.aliyuncs.com/compatible-mode/v1  qwen-turbo
//      Ollama   http://localhost:11434/v1                 qwen2.5 (key 随便填)
//  URLSession.shared 默认遵守系统代理(本机 Clash 7890 无需额外配置)。
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - OpenAI Chat Completions 极简客户端(无第三方依赖)

struct ChatMessage: Codable { let role, content: String }
struct ChatRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
}
struct ChatResponse: Codable {
    struct Choice: Codable { struct Message: Codable { let content: String }; let message: Message }
    let choices: [Choice]
}

func openAIChat(baseURL: String, model: String, apiKey: String?,
                system: String, user: String) async throws -> (text: String, ms: Double) {
    let root = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: root + "/chat/completions") else { throw E.badURL }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = 30
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
    let body = ChatRequest(model: model,
                           messages: [ChatMessage(role: "system", content: system),
                                      ChatMessage(role: "user", content: user)],
                           stream: false)
    req.httpBody = try JSONEncoder().encode(body)
    let t = Date()
    let (data, resp) = try await URLSession.shared.data(for: req)
    let ms = -t.timeIntervalSinceNow * 1000
    guard let http = resp as? HTTPURLResponse else { throw E.notHTTP }
    guard http.statusCode == 200 else {
        throw E.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
    }
    let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
    guard let first = decoded.choices.first else { throw E.emptyChoice }
    return (first.message.content.trimmingCharacters(in: .whitespacesAndNewlines), ms)
}

enum E: Error, CustomStringConvertible {
    case badURL, notHTTP, emptyChoice, serveExited, serveTimeout
    case httpError(Int, String)
    var description: String {
        switch self {
        case .badURL: return "baseURL 非法"
        case .notHTTP: return "非 HTTP 响应"
        case .emptyChoice: return "响应无 choices"
        case .serveExited: return "fm serve 进程意外退出"
        case .serveTimeout: return "fm serve 10s 内未就绪"
        case .httpError(let c, let b): return "HTTP \(c): \(b.prefix(200))"
        }
    }
}

// MARK: - fm serve 进程托管

actor FMServe {
    private var proc: Process?
    let port = 1976
    var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    func start() async throws {
        // 已在运行则直接复用
        if await healthOK() { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/fm")
        p.arguments = ["serve", "--port", String(port)]
        p.standardOutput = Pipe(); p.standardError = Pipe()   // 静音,避免阻塞
        proc = p
        try p.run()
        // 轮询 /health 最多 10s
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            if await healthOK() { return }
            if p.isRunning == false { throw E.serveExited }
        }
        throw E.serveTimeout
    }
    func stop() { proc?.terminate(); proc = nil }

    private func healthOK() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        do {
            let (_, r) = try await URLSession.shared.data(from: url)
            return (r as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }
}

// MARK: - 主流程

func main() async {
    let sys = "你是中文输入法的候选排序引擎。根据上文和拼音选出最符合语境的候选,只输出序号数字。"
    let user = "上文:这段子太绝了,我\n拼音:beng bu zhu le\n候选:1.蚌埠住了 2.绷不住了 3.蹦不住了"
    let rounds = 3

    print("========== 云端/本地模型三通道对照(同一案例 ×\(rounds) 轮) ==========")
    print("案例: beng bu zhu le —— 搞笑语境正确答案应为序号 2「绷不住了」\n")

    // 通道 1:进程内 FM
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        print("【通道1 fm-inproc】进程内 SystemLanguageModel")
        if case .available = SystemLanguageModel.default.availability {
            for i in 1...rounds {
                let t = Date()
                do {
                    let s = LanguageModelSession(model: .default, instructions: sys)
                    let r = try await s.respond(to: user)
                    print("  第\(i)轮: [\(r.content.trimmingCharacters(in: .whitespacesAndNewlines))] \(String(format: "%.0fms", -t.timeIntervalSinceNow*1000))")
                } catch { print("  第\(i)轮错误: \(error)") }
            }
        } else {
            print("  FM 不可用,跳过")
        }
        print("")
    }
    #endif

    // 通道 2:fm serve(OpenAI 协议调本地 FM)
    print("【通道2 fm-serve】HTTP → 本机 fm serve(OpenAI 兼容协议)")
    let serve = FMServe()
    do {
        try await serve.start()
        for i in 1...rounds {
            do {
                let r = try await openAIChat(baseURL: serve.baseURL, model: "system", apiKey: nil,
                                             system: sys, user: user)
                print("  第\(i)轮: [\(r.text)] \(String(format: "%.0fms", r.ms))")
            } catch { print("  第\(i)轮错误: \(error)") }
        }
    } catch {
        print("  fm serve 启动失败: \(error)")
    }
    await serve.stop()
    print("")
    // 通道 3:云端(环境变量配置,未配置则跳过)
    let env = ProcessInfo.processInfo.environment
    print("【通道3 cloud】OpenAI 兼容云端")
    guard let base = env["CLOUD_BASE_URL"], let key = env["CLOUD_API_KEY"],
          let modelName = env["CLOUD_MODEL"] else {
        print("  未配置环境变量,跳过。配置方法(任选一家,在终端 export 后重跑):")
        print("  export CLOUD_BASE_URL=https://api.deepseek.com/v1 CLOUD_API_KEY=sk-xxx CLOUD_MODEL=deepseek-chat")
        print("  # OpenAI/豆包方舟/通义/Ollama 同理,见文件头注释;URLSession 自动走系统代理 7890")
        return
    }
    print("  endpoint=\(base)  model=\(modelName)")
    for i in 1...rounds {
        do {
            let r = try await openAIChat(baseURL: base, model: modelName, apiKey: key,
                                         system: sys, user: user)
            print("  第\(i)轮: [\(r.text)] \(String(format: "%.0fms", r.ms))")
        } catch { print("  第\(i)轮错误: \(error)") }
    }
    print("\n完成。")
}

setbuf(stdout, nil)   // 管道下也实时输出
let sem = DispatchSemaphore(value: 0)
Task {
    defer { sem.signal() }
    await main()
}
sem.wait()
