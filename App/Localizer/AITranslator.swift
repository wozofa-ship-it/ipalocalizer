import Foundation

/// 翻译方式：内置免费接口 / 用户自定义 OpenAI 兼容接口。
enum TranslateMode: String, Sendable {
    case builtin   // 内置免费翻译（MyMemory），开箱即用
    case custom    // 用户自己的 OpenAI 兼容接口
}

/// AI 翻译配置。
/// - 内置模式：无需 Key，开箱即用。
/// - 自定义模式：Key 只存本机 UserDefaults，不上传到填写地址外的服务器。
struct AIConfig: Sendable {
    var mode: TranslateMode
    var enabled: Bool      // 总开关（两个模式共用）
    var apiKey: String
    var baseURL: String
    var model: String

    static func load() -> AIConfig {
        let d = UserDefaults.standard
        let modeRaw = d.string(forKey: "ai_mode") ?? TranslateMode.builtin.rawValue
        let base = d.string(forKey: "ai_base") ?? ""
        let model = d.string(forKey: "ai_model") ?? ""
        // v2 key defaults to false (off, local dict only); fallback to old key for migration
        let enabled: Bool
        if d.object(forKey: "ai_enabled_v2") != nil {
            enabled = d.bool(forKey: "ai_enabled_v2")
        } else if d.object(forKey: "ai_enabled") != nil {
            enabled = d.bool(forKey: "ai_enabled")
        } else {
            enabled = false
        }
        return AIConfig(
            mode: TranslateMode(rawValue: modeRaw) ?? .builtin,
            enabled: enabled,
            apiKey: d.string(forKey: "ai_key") ?? "",
            baseURL: base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "https://api.openai.com/v1" : base,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "gpt-4o-mini" : model
        )
    }

    /// 内置模式只要开了总开关就能用；自定义模式还需要 Key。
    var isReady: Bool {
        guard enabled else { return false }
        switch mode {
        case .builtin:
            return true
        case .custom:
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// 翻译器：内置免费接口（MyMemory）+ OpenAI 兼容接口。
enum AITranslator {

    // MARK: - 内置免费翻译（MyMemory，无需 Key）

    private struct MyMemoryResponse: Decodable {
        struct RespData: Decodable { let translatedText: String }
        let responseData: RespData
        let responseStatus: Int
    }

    /// 用 MyMemory 免费接口翻译单句。失败返回 nil（调用方跳过，不中断）。
    /// 注意：免费版有频率限制，调用方应在两次调用间加延迟。
    /// 返回 (译文, 是否被限流) 元组，限流时调用方应停止继续请求。
    static func translateBuiltin(_ text: String) async -> (String?, Bool) {
        guard let encoded = text.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string:
                "https://api.mymemory.translated.net/get?q=\(encoded)&langpair=en|zh-CN")
        else { return (nil, false) }

        var req = URLRequest(url: url)
        req.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return (nil, false) }
            // 429 = 被限流，告诉调用方停止
            if http.statusCode == 429 { return (nil, true) }
            guard (200..<300).contains(http.statusCode) else { return (nil, false) }
            let decoded = try JSONDecoder().decode(MyMemoryResponse.self, from: data)
            // MyMemory 用 429 或特定 status 表示限流
            if decoded.responseStatus == 429 { return (nil, true) }
            guard decoded.responseStatus == 200 else { return (nil, false) }
            var zh = decoded.responseData.translatedText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // MyMemory 有时会返回 "MYMEMORY WARNING" 之类的占位，视为限流
            if zh.uppercased().contains("MYMEMORY") { return (nil, true) }
            if zh.isEmpty { return (nil, false) }
            // 去掉可能的原文回显
            if zh == text { return (nil, false) }
            return (zh, false)
        } catch {
            return (nil, false)
        }
    }

    // MARK: - OpenAI 兼容接口（自定义 Key）

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }

    /// 批量翻译，返回与输入顺序一致的译文数组。
    /// 失败时抛 AIError，调用方应捕获后把本批标记为未翻译（不中断整体流程）。
    static func translateBatch(
        _ texts: [String], config: AIConfig
    ) async throws -> [String] {
        guard config.isReady else { throw AIError.notConfigured }

        let base = config.baseURL.trimmingCharacters(
            in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions") else {
            throw AIError.badResponse(-1)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(config.apiKey)",
                     forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 90

        let numbered = texts.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let body: [String: Any] = [
            "model": config.model,
            "temperature": 0.2,
            "messages": [
                [
                    "role": "system",
                    "content": "你是 iOS 应用 UI 文案汉化助手。将英文 UI 字符串翻译成简体中文。要求：译文简短，符合中文用户习惯；只返回译文，不要解释；技术术语（Bundle ID、URL Scheme、IPA、Info.plist、TestFlight 等）保留英文；如果是代码标识符、URL 或路径，请原样返回。",
                ],
                [
                    "role": "user",
                    "content": "翻译以下英文 UI 字符串，返回 JSON 数组（只含译文字符串，顺序与输入一致）：\n" + numbered,
                ],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw AIError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIError.badResponse(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AIError.badResponse(http.statusCode)
        }

        let decoded: ChatResponse
        do {
            decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw AIError.parseFailed
        }
        guard var content = decoded.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.emptyResult
        }

        // 去掉可能的 ```json 代码围栏
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.hasPrefix("```") {
            var lines = content.components(separatedBy: "\n")
            if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" {
                lines.removeLast()
            }
            content = lines.joined(separator: "\n")
        }
        guard let arrData = content.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(
                with: arrData) as? [String],
              arr.count == texts.count else {
            throw AIError.parseFailed
        }
        return arr
    }
}
