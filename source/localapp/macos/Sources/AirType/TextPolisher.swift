import Foundation

/// localapp: optional "停錄後 LLM 整理" — after recording stops, send the final ASR text to the user's
/// local OpenAI-compatible LLM (oMLX, from ~/.airtype/config.toml [[webui.llm-server]] default server)
/// for typo / punctuation / proper-noun cleanup. Thinking is forced OFF for speed.
/// Any failure (network, timeout, empty / suspicious output) returns nil so the caller pastes the original ASR text.
enum TextPolisher {
    static let defaultsKey = "llmPolishEnabled"

    /// Menu toggle (default on). AIRTYPE_LLM_POLISH=0 forces it off.
    static var enabled: Bool {
        if ProcessInfo.processInfo.environment["AIRTYPE_LLM_POLISH"] == "0" { return false }
        return UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// 停錄後整理固定用這顆（oMLX model id，6bit）；AIRTYPE_LLM_POLISH_MODEL 可覆寫。不跟 WebUI selected-model 走。
    static let defaultModel = "Qwen3.6-35B-A3B-MLX-6bit"

    static let systemPrompt = "你是中文語音輸入後處理。只修正明顯錯字、標點、專有名詞；若說話者提到「有幾點／幾項」、「第一、第二…」或「一是…二是…」等列舉，請在每一項前斷行，改成條列，每項一行，格式為「1. …」「2. …」，列表前的引言保留為獨立一行；沒有列舉就不要硬改成條列。口述常有重說、改口或換句話重講同一件事（例如「我想要你去。我想讓你去幫我做一件事情。」），遇到前後句意思相同或重疊時，請合併成一句自然的話（例：「我想讓你去幫我做一件事情。」），不要重複保留；以較完整、較後面的說法為主，若前句有後句沒有的細節則併入；不同的意思不可刪除，只去掉重複。保留中英夾雜與原意。數字保持阿拉伯數字。不要加標題、不要解釋、不要思考過程。只輸出整理後全文。"

    static var timeoutSeconds: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["AIRTYPE_LLM_POLISH_TIMEOUT"], let value = Double(raw), value > 0 {
            return value
        }
        return 15
    }

    static func polish(_ text: String, llm: LLMServerConfig, completion: @escaping (String?) -> Void) {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { completion(nil); return }
        // Polish has its own fixed model (endpoint / api key still come from the config's default LLM server).
        let model = ProcessInfo.processInfo.environment["AIRTYPE_LLM_POLISH_MODEL"] ?? defaultModel
        var base = llm.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let urlString = base.hasSuffix("/v1") ? "\(base)/chat/completions" : "\(base)/v1/chat/completions"
        guard !model.isEmpty, let url = URL(string: urlString) else {
            Logger.shared.log("LLM polish skipped: missing endpoint/model (endpoint=\(llm.endpoint), model=\(model))")
            completion(nil)
            return
        }

        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": input],
            ],
            // Thinking OFF (fastest): Qwen chat template flag + Ollama-style flag. No thinking_budget.
            "chat_template_kwargs": ["enable_thinking": false],
            "think": false,
        ]
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Cloudflare in front of omlx.dougpuob.uk may challenge non-browser user agents.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130 Safari/537.36 AirType",
            forHTTPHeaderField: "User-Agent"
        )
        if !llm.apiKey.isEmpty {
            request.setValue("Bearer \(llm.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let started = Date()
        URLSession.shared.dataTask(with: request) { data, response, error in
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
            if let error {
                Logger.shared.log("LLM polish failed after \(elapsed)s: \(error.localizedDescription)")
                completion(nil)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                Logger.shared.log("LLM polish failed after \(elapsed)s: HTTP \(status), unexpected response")
                completion(nil)
                return
            }
            let cleaned = clean(content)
            guard isPlausible(cleaned, original: input) else {
                Logger.shared.log("LLM polish rejected after \(elapsed)s: implausible output chars=\(cleaned.count) vs input=\(input.count)")
                completion(nil)
                return
            }
            Logger.shared.log("LLM polish ok in \(elapsed)s model=\(model) chars \(input.count)->\(cleaned.count)")
            completion(cleaned)
        }.resume()
    }

    /// Drops any leaked reasoning (everything up to the last </think>) and wrapping code fences.
    static func clean(_ content: String) -> String {
        var text = content
        if let range = text.range(of: "</think>", options: .backwards) {
            text = String(text[range.upperBound...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") && text.hasSuffix("```") && text.count > 6 {
            text = String(text.dropFirst(3).dropLast(3))
            if let newline = text.firstIndex(of: "\n"), !text[..<newline].contains(" ") {
                text = String(text[text.index(after: newline)...])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Cleanup should not change length much; reject answers / essays / truncations.
    private static func isPlausible(_ output: String, original: String) -> Bool {
        guard !output.isEmpty, !output.contains("<think>") else { return false }
        let maxCount = Int(Double(original.count) * 1.6) + 20
        let minCount = Int(Double(original.count) * 0.5)
        return output.count <= maxCount && output.count >= minCount
    }
}
