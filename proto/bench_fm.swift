// 进程内 FoundationModels 延迟基准 —— 模拟输入法的真实调用模式:
// 1) 会话冷启动  2) 复用会话的暖场调用  3) 流式首 token  4) 整句预测
import Foundation
import FoundationModels

func fmt(_ v: TimeInterval) -> String { String(format: "%.3f", v) }
let t = { Date() }

let sem = DispatchSemaphore(value: 0)

Task {
    defer { sem.signal() }
    let model = SystemLanguageModel.default
    print("availability: \(model.availability)")
    guard case .available = model.availability else { print("模型不可用,退出"); return }

    let instructions = "你是中文拼音输入法的候选预测引擎。回答必须极简,只输出结果本身,禁止解释。"

    // 1) 冷启动: 新建 session 到首个请求完成
    var t0 = t()
    let session = LanguageModelSession(model: model, instructions: instructions)
    print("session 创建: \(fmt(t().timeIntervalSince(t0)))s")

    t0 = t()
    let cold = try await session.respond(to: "回复:好")
    print("冷启动首请求: \(fmt(t().timeIntervalSince(t0)))s -> \(cold.content)")

    // 2) 暖场: 复用 session,典型候选重排调用 ×3
    let rerank = """
    上文:「今天天气真好,我们去」。拼音:gongyuan。
    候选:公园/公员/工院/宫原。只输出1个最合适的词。
    """
    for i in 1...3 {
        t0 = t()
        let r = try await session.respond(to: rerank)
        print("暖场重排#\(i): \(fmt(t().timeIntervalSince(t0)))s -> \(r.content)")
    }

    // 3) 流式: 首 token 延迟 + 总时长(整句预测场景)
    let sent = "拼音:jin tian tian qi zen me yang。转成中文,只输出句子。"
    t0 = t()
    var first: TimeInterval?
    var text = ""
    for try await chunk in session.streamResponse(to: sent) {
        if first == nil { first = t().timeIntervalSince(t0) }
        text = String(describing: chunk)
    }
    print("流式整句: 首 token \(fmt(first!))s / 总 \(fmt(t().timeIntervalSince(t0)))s -> \(text)")

    // 4) 每次新建 session(对比: 是否复用更慢/更快)
    t0 = t()
    let fresh = LanguageModelSession(model: model, instructions: instructions)
    let fr = try await fresh.respond(to: rerank)
    print("新建session+重排: \(fmt(t().timeIntervalSince(t0)))s -> \(fr.content)")

    // 5) 长一点的整句,估算生成速度
    let long = "拼音:qing ni ba zhe ju hua fan yi cheng zhong wen ju zi。转成中文,只输出结果。"
    t0 = t()
    let lr = try await session.respond(to: long)
    let dt = t().timeIntervalSince(t0)
    let n = lr.content.count
    print("长句: \(fmt(dt))s (\(n)字, \(fmt(Double(n)/dt))字/s) -> \(lr.content)")
}

sem.wait()
