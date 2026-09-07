import Foundation
import FoundationModels

/// 云端模型经 FoundationModels 官方 Provider 协议(LanguageModel + LanguageModelExecutor)接入——
/// 上层仍用标准 LanguageModelSession(instructions+prompt 的 transcript 映射由框架完成),
/// Executor 只做 transcript → 线格式 的转换。架构 = ProviderBench 验证版(WWDC26 Provider 最小实现)。
/// 线格式(kb36「模型」页可选):
///   openai    POST {base}/chat/completions  instructions→system,prompt→user;Authorization: Bearer
///   anthropic POST {base}/v1/messages       instructions→system 参数,prompt→user;x-api-key +
///                                           anthropic-version: 2023-06-01;max_tokens 必带(取 1024)
public struct CloudProviderModel: LanguageModel {
    public typealias Executor = CloudProviderExecutor

    public struct Config: Hashable, Sendable {
        public var baseURL: URL        // 接口前缀,如 https://api.deepseek.com/v1
        public var modelName: String
        public var apiKey: String
        public var wireFormat: String  // "openai" | "anthropic"
        public init(baseURL: URL, modelName: String, apiKey: String, wireFormat: String) {
            self.baseURL = baseURL
            self.modelName = modelName
            self.apiKey = apiKey
            self.wireFormat = wireFormat
        }
    }

    public let config: Config
    public init(config: Config) { self.config = config }

    public var capabilities: LanguageModelCapabilities {
        // 与 ProviderBench 实测一致;框架仅在真用到缺失能力时才校验
        LanguageModelCapabilities([.guidedGeneration, .toolCalling, .reasoning])
    }
    public var executorConfiguration: Config { config }

    /// 从 ModelPrefs 读配置;URL 无 host 或 scheme 非 http(s) 视为未配置(返回 nil → 走端侧)
    public static func configured() -> Config? {
        let raw = UserDefaults.standard.string(forKey: ModelPrefs.cloudBaseURLKey) ?? ""
        guard !raw.isEmpty, let url = URL(string: raw), let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let model = UserDefaults.standard.string(forKey: ModelPrefs.cloudModelKey), !model.isEmpty
        else { return nil }
        return Config(
            baseURL: url,
            modelName: model,
            apiKey: UserDefaults.standard.string(forKey: ModelPrefs.cloudAPIKeyKey) ?? "",
            wireFormat: ModelPrefs.cloudFormat)
    }

    /// 设置中心「测试连接」:最小请求往返,返回人读结果(✓/✗ + 耗时)
    public static func probe(baseURL: String, apiKey: String, modelName: String, wireFormat: String) async -> String {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)),
              let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) else {
            return "✗ 接口地址非法(远程仅支持 https,本机 http 如 Ollama 可用)"
        }
        guard !modelName.isEmpty else { return "✗ 请先填模型名" }
        let cfg = Config(baseURL: url, modelName: modelName, apiKey: apiKey, wireFormat: wireFormat)
        let t0 = Date()
        do {
            let session = LanguageModelSession(model: CloudProviderModel(config: cfg),
                                               instructions: "你是连接测试器。只回复两个字:成功")
            let resp = try await session.respond(to: "测试连接,请回复:成功")
            let ms = Int(-t0.timeIntervalSinceNow * 1000)
            let out = resp.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return "✓ 连接成功 \(ms)ms · 响应:「\(out.prefix(30))」"
        } catch {
            let ms = Int(-t0.timeIntervalSinceNow * 1000)
            return "✗ 连接失败(\(ms)ms):\(error.localizedDescription)"
        }
    }
}

public actor CloudProviderExecutor: LanguageModelExecutor {
    public typealias Model = CloudProviderModel
    public typealias Configuration = CloudProviderModel.Config

    public let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration) throws {
        self.configuration = configuration
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15   // 云端比端侧慢;超时即失败回落端侧,不无限等
        c.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: c)
    }

    nonisolated static func plainText(_ segments: [Transcript.Segment]) -> String {
        segments.compactMap { seg in
            switch seg {
            case .text(let t): return t.content
            case .structure, .attachment: return nil
            @unknown default: return nil
            }
        }.joined()
    }

    // MARK: - 线格式体(openai)

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

    // MARK: - 线格式体(anthropic)

    private struct ANMsg: Codable { let role, content: String }
    private struct ANReq: Codable {
        let model: String
        let system: String?
        let messages: [ANMsg]
        let maxTokens: Int
        enum CodingKeys: String, CodingKey {
            case model, system, messages
            case maxTokens = "max_tokens"
        }
    }
    private struct ANResp: Codable {
        struct Block: Codable { let type: String?; let text: String? }
        let content: [Block]
    }

    public func respond(to request: LanguageModelExecutorGenerationRequest,
                        model: CloudProviderModel,
                        streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        let cfg = configuration
        let anthropic = cfg.wireFormat == "anthropic"

        // transcript → 线格式(instructions=system,prompt/响应=user/assistant)
        var oaMessages = [OAMsg]()
        var anMessages = [ANMsg]()
        var systemText: String?
        for entry in request.transcript {
            switch entry {
            case .instructions(let ins):
                let text = Self.plainText(ins.segments)
                if anthropic { systemText = text } else { oaMessages.append(OAMsg(role: "system", content: text)) }
            case .prompt(let p):
                let text = Self.plainText(p.segments)
                if anthropic { anMessages.append(ANMsg(role: "user", content: text)) }
                else { oaMessages.append(OAMsg(role: "user", content: text)) }
            case .response(let r):
                let text = Self.plainText(r.segments)
                if anthropic { anMessages.append(ANMsg(role: "assistant", content: text)) }
                else { oaMessages.append(OAMsg(role: "assistant", content: text)) }
            case .reasoning, .toolCalls, .toolOutput:
                break   // 最小实现:不转推理链/工具调用
            @unknown default: break
            }
        }

        // GenerationOptions → 后端参数(greedy 近似为 temperature 0)
        var temp = request.generationOptions.temperature
        if request.generationOptions.samplingMode == .greedy { temp = 0 }

        var req: URLRequest
        var body: Data
        if anthropic {
            req = URLRequest(url: cfg.baseURL.appendingPathComponent("v1/messages"))
            body = try JSONEncoder().encode(
                ANReq(model: cfg.modelName, system: systemText, messages: anMessages, maxTokens: 1024))
            req.setValue(cfg.apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            req = URLRequest(url: cfg.baseURL.appendingPathComponent("chat/completions"))
            body = try JSONEncoder().encode(
                OAReq(model: cfg.modelName, messages: oaMessages, temperature: temp, stream: false))
            req.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, urlResp) = try await session.data(for: req)
        guard let http = urlResp as? HTTPURLResponse else {
            throw LanguageModelError.timeout(.init(debugDescription: "非 HTTP 响应"))
        }
        guard http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 429 {
                throw LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "HTTP 429"))
            }
            throw LanguageModelError.timeout(.init(debugDescription: "HTTP \(http.statusCode): \(detail.prefix(160))"))
        }

        let answer: String
        if anthropic {
            let decoded = try JSONDecoder().decode(ANResp.self, from: data)
            answer = decoded.content.first(where: { $0.type == "text" || $0.text != nil })?.text ?? ""
        } else {
            let decoded = try JSONDecoder().decode(OAResp.self, from: data)
            answer = decoded.choices.first?.message.content ?? ""
        }
        guard !answer.isEmpty else { return }

        // 回灌框架:一次性 appendText(SSE 流式场景可按 delta 多次 append)
        await channel.send(.response(action: .appendText(answer, tokenCount: answer.count)))
    }
}
