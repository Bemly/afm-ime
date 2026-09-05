// 决定性实验:按 macOS 27 官方 Provider 协议,把一个 OpenAI 兼容后端(此处接本机 fm serve)
// 接进 FoundationModels 的 LanguageModelSession —— 证明框架层可接任意第三方模型。
//
// 架构(WWDC26 "Bring an LLM provider to the Foundation Models framework" 的最小实现):
//   OpenAICompatModel (LanguageModel = 模型描述符:能力 + Executor 配置)
//        └─ OpenAICompatExecutor (LanguageModelExecutor = 协议转换器)
//               request.transcript → OpenAI messages[]
//               request.generationOptions → temperature/max_tokens
//               HTTP /v1/chat/completions → channel.appendText 回灌框架
//
// 把 baseURL 换成 DeepSeek/OpenAI/豆包/通义/Ollama,即成为对应云端 Provider。
import Foundation
import FoundationModels

// MARK: - OpenAI Chat Completions 线格式

private struct OAMsg: Codable { let role, content: String }
private struct OAReq: Codable {
    let model: String
    let messages: [OAMsg]
    let temperature: Double?
    let stream: Bool
}
private struct OAResp: Codable {
    struct Choice: Codable { struct Msg: Codable { let content: String }; let message: Msg }
    let choices: [Choice]
}

// MARK: - ① Configuration:框架按它缓存 Executor(必须 Hashable + Sendable)

struct OpenAICompatConfig: Hashable, Sendable {
    let baseURL: URL       // 例: http://127.0.0.1:1976/v1 或 https://api.deepseek.com/v1
    let modelName: String  // 例: system / deepseek-chat / gpt-4o-mini
    let apiKey: String?
}

// MARK: - ② Model 描述符

@available(macOS 27.0, *)
struct OpenAICompatModel: LanguageModel {
    typealias Executor = OpenAICompatExecutor
    let config: OpenAICompatConfig

    // 向框架声明能力;框架会在调用前校验(缺 guidedGeneration 却用 schema 会直接抛 unsupportedCapability)
    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.guidedGeneration, .toolCalling, .reasoning])
    }
    var executorConfiguration: OpenAICompatExecutor.Configuration { config }
}

// MARK: - ③ Executor:真正的协议转换器

@available(macOS 27.0, *)
actor OpenAICompatExecutor: LanguageModelExecutor {
    typealias Model = OpenAICompatModel
    typealias Configuration = OpenAICompatConfig
    let configuration: Configuration
    private let session: URLSession

    init(configuration: Configuration) throws {
        self.configuration = configuration
        self.session = URLSession.shared
    }

    // prewarm 有默认实现,可不写;真实云端 Provider 可在这里预热连接池

    nonisolated static func plainText(_ segments: [Transcript.Segment]) -> String {
        segments.compactMap { seg in
            switch seg {
            case .text(let t): return t.content
            case .structure, .attachment: return nil
            @unknown default: return nil
            }
        }.joined()
    }

    func respond(to request: LanguageModelExecutorGenerationRequest,
                 model: OpenAICompatModel,
                 streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        // 1) Transcript → OpenAI messages(instructions=system, prompt=user, response=assistant)
        var messages = [OAMsg]()
        for entry in request.transcript {
            switch entry {
            case .instructions(let ins):
                messages.append(OAMsg(role: "system", content: Self.plainText(ins.segments)))
            case .prompt(let p):
                messages.append(OAMsg(role: "user", content: Self.plainText(p.segments)))
            case .response(let r):
                messages.append(OAMsg(role: "assistant", content: Self.plainText(r.segments)))
            case .reasoning, .toolCalls, .toolOutput:
                break   // 最小实现:不转推理链/工具调用
            @unknown default: break
            }
        }

        // 2) GenerationOptions → 后端参数(greedy 近似为 temperature 0,官方推荐做法)
        var temp: Double? = request.generationOptions.temperature
        if request.generationOptions.samplingMode == .greedy { temp = 0 }
        let body = try JSONEncoder().encode(
            OAReq(model: configuration.modelName, messages: messages, temperature: temp, stream: false))

        // 3) 发请求(错误可映射为 LanguageModelError,如 429→.rateLimited)
        var req = URLRequest(url: configuration.baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"; req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = configuration.apiKey { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.httpBody = body
        let (data, urlResp) = try await session.data(for: req)
        guard let http = urlResp as? HTTPURLResponse else {
            throw LanguageModelError.timeout(.init(debugDescription: "非 HTTP 响应"))
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 429 {
                throw LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "HTTP 429"))
            }
            throw LanguageModelError.timeout(.init(debugDescription: "HTTP \(http.statusCode)"))
        }
        let decoded = try JSONDecoder().decode(OAResp.self, from: data)
        guard let answer = decoded.choices.first?.message.content else { return }

        // 4) 回灌框架:一次性 appendText(真实 SSE 场景可按 delta 多次 append 实现流式)
        await channel.send(.response(action: .appendText(answer, tokenCount: answer.count)))
        // 方法返回即结束 channel,无需显式 close
    }
}

// MARK: - fm serve 托管(为本机实验提供 OpenAI 兼容后端)

actor FMServe {
    private var proc: Process?
    let port = 1976
    var v1: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }
    func start() async throws {
        if await ok() { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/fm")
        p.arguments = ["serve", "--port", String(port)]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        proc = p; try p.run()
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            if await ok() { return }
            if !p.isRunning { throw NSError(domain: "fmserve", code: 1) }
        }
    }
    func stop() { proc?.terminate(); proc = nil }
    private func ok() async -> Bool {
        do { let (_, r) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
             return (r as? HTTPURLResponse)?.statusCode == 200 } catch { return false }
    }
}

// MARK: - 主流程

@available(macOS 27.0, *)
func run() async {
    setbuf(stdout, nil)
    let sys = "你是中文输入法的候选排序引擎。根据上文和拼音选出最符合语境的候选,只输出序号数字。"
    let user = "上文:这段子太绝了,我\n拼音:beng bu zhu le\n候选:1.蚌埠住了 2.绷不住了 3.蹦不住了"

    let serve = FMServe()
    do { try await serve.start() } catch { print("fm serve 启动失败: \(error)"); return }
    defer { Task { await serve.stop() } }

    // —— 对照 A:系统自带 AFM ——
    print("========== 官方 Provider 协议接入实验 ==========")
    print("【A 系统模型 SystemLanguageModel】")
    for i in 1...3 {
        let t = Date()
        let s = LanguageModelSession(model: .default, instructions: sys)
        do { let r = try await s.respond(to: user)
            print("  第\(i)轮: [\(r.content.trimmingCharacters(in: .whitespaces))] \(String(format: "%.0fms", -t.timeIntervalSinceNow*1000))")
        } catch { print("  第\(i)轮错误: \(error)") }
    }

    // —— 对照 B:自定义 Provider(走 LanguageModel 协议,后端是 fm serve,换 URL 即云端) ——
    print("\n【B 自定义 OpenAICompatModel(官方 LanguageModel/Executor 协议,后端 fm serve)】")
    let customModel = OpenAICompatModel(config: .init(
        baseURL: await serve.v1, modelName: "system", apiKey: nil))
    for i in 1...3 {
        let t = Date()
        // 注意:这里上层用的是完全标准的 FoundationModels API,看不出后端不是 AFM
        let s = LanguageModelSession(model: customModel, instructions: sys)
        do { let r = try await s.respond(to: user)
            print("  第\(i)轮: [\(r.content.trimmingCharacters(in: .whitespaces))] \(String(format: "%.0fms", -t.timeIntervalSinceNow*1000))")
        } catch { print("  第\(i)轮错误: \(error)") }
    }

    // —— 通用性验证:普通问答 ——
    print("\n【C 通用性:同一自定义 Provider 回答普通问题】")
    let s3 = LanguageModelSession(model: customModel)
    do { let r = try await s3.respond(to: "用一句话说明拼音输入法是做什么的。")
        print("  \(r.content.trimmingCharacters(in: .whitespacesAndNewlines))")
    } catch { print("  错误: \(error)") }

    try? await Task.sleep(for: .milliseconds(300))
    print("\n完成。")
}

if #available(macOS 27.0, *) {
    let sem = DispatchSemaphore(value: 0)
    Task { defer { sem.signal() }; await run() }
    sem.wait()
} else { print("需要 macOS 27+") }
