import Foundation

struct TranscriptionResponse: Decodable {
    let text: String?
}

final class BackendClient {
    func transcribeIME(wavData: Data, endpoint: String, language: String, inputID: Int? = nil) async throws -> String {
        let url = URL(string: endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/transcribe/ime")!
        let startedAt = Date()
        let logPrefix = inputID.map { "Input #\($0): " } ?? ""
        let boundary = "----AirType\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(
            boundary: boundary,
            fields: [
                "beam_size": "1",
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
            throw NSError(domain: "AirTypeMac.Backend", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
        }

        if let http = response as? HTTPURLResponse {
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            Logger.shared.log("\(logPrefix)ASR response received: status=\(http.statusCode), bytes=\(data.count), elapsed_ms=\(elapsedMs)")
        }
        let payload = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty {
            throw NSError(domain: "AirTypeMac.Backend", code: 2, userInfo: [NSLocalizedDescriptionKey: "ASR completed without text"])
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

    func fetchAllLLMModels(endpoint: String) async throws -> [LLMModel] {
        let url = URL(string: endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/local-llm/all-models")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
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
