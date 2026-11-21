import Foundation

struct TranscriptionResponse: Decodable {
    let text: String?
}

final class BackendClient {
    func transcribeIME(wavData: Data, endpoint: String, language: String, auth: WebUIAuthConfig, beam: Int? = nil, inputID: Int? = nil) async throws -> String {
        let url = URL(string: endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/transcribe/ime")!
        let startedAt = Date()
        let logPrefix = inputID.map { "Input #\($0): " } ?? ""
        let boundary = "----AirType\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyAuth(auth, to: &request)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(
            boundary: boundary,
            fields: [
                "beam_size": String(beam ?? 1),
                "record_type": "ime",
                "language": language
            ],
            wavData: wavData
        )

        Logger.shared.log("\(logPrefix)ASR request started: url=\(url.absoluteString), wav_bytes=\(wavData.count), language=\(language)")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "unknown error"
            if let http = response as? HTTPURLResponse {
                Logger.shared.log("\(logPrefix)ASR request failed: status=\(http.statusCode), detail=\(detail)")
            }
            throw NSError(domain: "AirType.Backend", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
        }

        if let http = response as? HTTPURLResponse {
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            Logger.shared.log("\(logPrefix)ASR response received: status=\(http.statusCode), bytes=\(data.count), elapsed_ms=\(elapsedMs)")
        }
        let payload = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty {
            throw NSError(domain: "AirType.Backend", code: 2, userInfo: [NSLocalizedDescriptionKey: "ASR completed without text"])
        }
        Logger.shared.log("\(logPrefix)ASR text received: chars=\(text.count)")
        return text
    }

    struct LLMModel: Decodable {
        let name: String
        let server: String?
    }

    struct AllModelsResponse: Decodable {
        let models: [LLMModel]
    }

    func fetchAllLLMModels(endpoint: String, auth: WebUIAuthConfig) async throws -> [LLMModel] {
        let url = URL(string: endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/local-llm/all-models")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyAuth(auth, to: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "unknown error"
            Logger.shared.log("fetchAllLLMModels failed: status=\(statusCode), detail=\(detail)")
            return []
        }
        let payload = try JSONDecoder().decode(AllModelsResponse.self, from: data)
        let models = payload.models.filter { !$0.name.isEmpty }
        Logger.shared.log("fetchAllLLMModels: found \(models.count) models")
        return models
    }

    /// Dispatches on the target's protocol. Returns trimmed text; throws on HTTP errors or empty text.
    func transcribe(wavData: Data, target: RemoteASRTarget, webuiLanguage: String, openAILanguage: String?) async throws -> String {
        switch target.protocolKind {
        case .webuiIME:
            return try await transcribeIME(wavData: wavData, endpoint: target.endpoint, language: webuiLanguage, auth: target.auth, beam: target.beam)
        case .openAITranscriptions:
            return try await transcribeOpenAI(wavData: wavData, target: target, language: openAILanguage)
        }
    }

    /// OpenAI-compatible `POST {endpoint}/v1/audio/transcriptions` (multipart: file, model, language?, response_format=json).
    func transcribeOpenAI(wavData: Data, target: RemoteASRTarget, language: String?) async throws -> String {
        guard let url = URL(string: target.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/audio/transcriptions") else {
            throw NSError(domain: "AirType.Backend", code: 3, userInfo: [NSLocalizedDescriptionKey: "invalid endpoint \(target.endpoint)"])
        }
        let startedAt = Date()
        let boundary = "----AirType\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        Self.applyAuth(target: target, to: &request)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var fields = ["response_format": "json"]
        if !target.model.isEmpty { fields["model"] = target.model }
        if let language { fields["language"] = language }
        request.httpBody = multipartBody(boundary: boundary, fields: fields, wavData: wavData)
        Logger.shared.log("ASR request started (openai): url=\(url.absoluteString), model=\(target.model), wav_bytes=\(wavData.count), language=\(language ?? "auto")")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = String(data: data, encoding: .utf8) ?? "unknown error"
            Logger.shared.log("ASR request failed (openai): status=\(status), detail=\(detail.prefix(300))")
            throw NSError(domain: "AirType.Backend", code: 1, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status): \(detail.prefix(200))"])
        }
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        Logger.shared.log("ASR response received (openai): status=\(status), bytes=\(data.count), elapsed_ms=\(elapsedMs)")
        let payload = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty {
            throw NSError(domain: "AirType.Backend", code: 2, userInfo: [NSLocalizedDescriptionKey: "ASR completed without text"])
        }
        return text
    }

    struct RemoteModelList {
        var models: [String]
        /// Protocol the server appears to speak (nil = not detected).
        var detectedProtocol: RemoteASRProtocol?
        var note: String
    }

    /// Model discovery for the Settings window:
    ///   1. GET /v1/models (OpenAI list) → protocol openai.
    ///   2. GET /api/health + /api/whisper-server/status (AirType WebUI) → protocol webui-ime, the WebUI's whisper model.
    func listRemoteModels(target: RemoteASRTarget) async -> RemoteModelList {
        let base = target.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var notes: [String] = []
        if let url = URL(string: base + "/v1/models") {
            var request = URLRequest(url: url, timeoutInterval: 8)
            Self.applyAuth(target: RemoteASRTarget(endpoint: base, protocolKind: .openAITranscriptions, model: "", apiKey: target.apiKey, auth: target.auth), to: &request)
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status), let ids = Self.parseOpenAIModelIDs(data) {
                    return RemoteModelList(models: ids, detectedProtocol: .openAITranscriptions,
                                           note: "OpenAI-compatible server: \(ids.count) models from /v1/models.")
                }
                notes.append(status == 401 || status == 403 ? "/v1/models: HTTP \(status) (check API key)" : "/v1/models: not available")
            } catch {
                notes.append("/v1/models: \(error.localizedDescription)")
            }
        }
        if let url = URL(string: base + "/api/health") {
            var request = URLRequest(url: url, timeoutInterval: 8)
            applyAuth(target.auth, to: &request)
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) {
                var models: [String] = []
                if let statusURL = URL(string: base + "/api/whisper-server/status") {
                    var statusRequest = URLRequest(url: statusURL, timeoutInterval: 8)
                    applyAuth(target.auth, to: &statusRequest)
                    if let (data, _) = try? await URLSession.shared.data(for: statusRequest),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let model = json["model"] as? String, !model.isEmpty {
                        models = [URL(fileURLWithPath: model).lastPathComponent]
                    }
                }
                return RemoteModelList(models: models, detectedProtocol: .webuiIME,
                                       note: "AirType WebUI: whisper-server model is set on the server; no model choice needed.")
            }
            notes.append("/api/health: not reachable")
        }
        return RemoteModelList(models: [], detectedProtocol: nil, note: "No model list. " + notes.joined(separator: "; "))
    }

    /// `{"data":[{"id":...}]}` → ids; nil if the body is not an OpenAI model list (e.g. an HTML page).
    static func parseOpenAIModelIDs(_ data: Data) -> [String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return nil }
        return list.compactMap { $0["id"] as? String }
    }

    /// openai: Bearer api_key (falls back to Basic [webui.auth] when no key). webui-ime: Basic [webui.auth].
    static func applyAuth(target: RemoteASRTarget, to request: inout URLRequest) {
        if target.protocolKind == .openAITranscriptions, !target.apiKey.isEmpty {
            request.setValue("Bearer \(target.apiKey)", forHTTPHeaderField: "Authorization")
            return
        }
        let auth = target.auth
        guard auth.enabled, !auth.username.isEmpty, !auth.password.isEmpty,
              let data = "\(auth.username):\(auth.password)".data(using: .utf8) else { return }
        request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
    }


    private func applyAuth(_ auth: WebUIAuthConfig, to request: inout URLRequest) {
        guard auth.enabled, !auth.username.isEmpty, !auth.password.isEmpty else { return }
        let token = "\(auth.username):\(auth.password)"
        guard let data = token.data(using: .utf8) else { return }
        request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
    }

    private func multipartBody(boundary: String, fields: [String: String], wavData: Data) -> Data {
        var body = Data()
        for (name, value) in fields {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        body.appendString("\r\n")
        body.appendString("--\(boundary)--\r\n")
        return body
    }
}
