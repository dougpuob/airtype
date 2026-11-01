import Foundation

/// Merged from localapp (AirTypeMac): Remote ASR through the AirType WebUI, which forwards the WAV to
/// whisper.cpp `whisper-server` (`POST {endpoint}/api/transcribe/ime`, multipart, HTTP Basic from [webui.auth]).
/// This app never starts uvicorn itself (no BackendProcessManager): the WebUI must already be running at the
/// selected endpoint (e.g. https://airtype.dougpuob.uk on msm4max, or http://localhost:8003).
///
/// Not streaming: PCM is buffered while recording and uploaded once on stop, so there are no partial results
/// (Live Typing is disabled while Remote is selected; the final text is pasted on stop).

/// Wire protocol of the remote server.
enum RemoteASRProtocol: String, CaseIterable {
    /// AirType WebUI `/api/transcribe/ime` (whisper.cpp behind it), HTTP Basic from [webui.auth].
    case webuiIME = "webui-ime"
    /// OpenAI-compatible `POST /v1/audio/transcriptions` (e.g. oMLX + mlx-audio STT model),
    /// `model` + Bearer API key from [localapp.remote-asr].
    case openAITranscriptions = "openai"

    var title: String {
        switch self {
        case .webuiIME: return "AirType WebUI"
        case .openAITranscriptions: return "OpenAI Compatible"
        }
    }
}

/// Everything needed to talk to one remote ASR server.
struct RemoteASRTarget {
    var endpoint: String
    var protocolKind: RemoteASRProtocol
    var model: String
    var apiKey: String
    var auth: WebUIAuthConfig
}

/// Remote endpoint choices + auth, populated by the coordinator from the config
/// ([localapp.backend-endpoint] remote_endpoint / local_endpoint, [webui.auth]) and UserDefaults.
/// Read and written on the main thread only.
enum RemoteWhisperSettings {
    static let endpointDefaultsKey = "asrRemoteEndpoint"
    /// Env override: AIRTYPE_REMOTE_ENDPOINT=https://host (always listed first and selected).
    static var envEndpoint: String? {
        let raw = ProcessInfo.processInfo.environment["AIRTYPE_REMOTE_ENDPOINT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : normalize(raw)
    }

    static var endpoints: [String] = []
    static var defaultEndpoint = ""
    static var auth = WebUIAuthConfig()
    /// [localapp.remote-asr] (Settings ▸ Remote ASR). Its endpoint is listed first and owns protocol/model/api_key;
    /// the [localapp.backend-endpoint] endpoints always use the WebUI protocol.
    static var remoteASR = RemoteASRConfig()

    static func configure(backend: BackendConfig, auth: WebUIAuthConfig, remoteASR: RemoteASRConfig = RemoteASRConfig()) {
        self.remoteASR = remoteASR
        var list: [String] = []
        for candidate in [envEndpoint, normalize(remoteASR.endpoint), normalize(backend.remoteEndpoint), normalize(backend.localEndpoint)] {
            guard let value = candidate, !value.isEmpty, !list.contains(value) else { continue }
            list.append(value)
        }
        endpoints = list
        let configPreferred = backend.mode.lowercased() == "local" ? backend.remoteEndpoint : backend.selectedEndpoint
        defaultEndpoint = envEndpoint ?? normalize(remoteASR.endpoint) ?? normalize(configPreferred) ?? list.first ?? ""
        if defaultEndpoint.isEmpty { defaultEndpoint = list.first ?? "" }
        self.auth = auth
    }

    /// Env override > menu choice (UserDefaults, if still configured) > config remote_endpoint.
    static var selectedEndpoint: String {
        if let env = envEndpoint { return env }
        if let stored = UserDefaults.standard.string(forKey: endpointDefaultsKey), endpoints.contains(stored) {
            return stored
        }
        return defaultEndpoint
    }

    static func select(_ endpoint: String) {
        UserDefaults.standard.set(endpoint, forKey: endpointDefaultsKey)
    }

    /// Protocol / model / key for an endpoint: the [localapp.remote-asr] endpoint uses its own settings,
    /// any other endpoint is an AirType WebUI.
    static func target(for endpoint: String) -> RemoteASRTarget {
        if let configured = normalize(remoteASR.endpoint), configured == endpoint {
            return RemoteASRTarget(
                endpoint: endpoint,
                protocolKind: RemoteASRProtocol(rawValue: remoteASR.protocolName) ?? .webuiIME,
                model: remoteASR.model,
                apiKey: remoteASR.apiKey,
                auth: auth
            )
        }
        return RemoteASRTarget(endpoint: endpoint, protocolKind: .webuiIME, model: "", apiKey: "", auth: auth)
    }

    /// OpenAI `language` (ISO-639-1); nil lets the server auto-detect.
    static func openAILanguage(forMode mode: String) -> String? {
        switch mode {
        case "en": return "en"
        case "zh-tw", "zh-cn": return "zh"
        default: return nil
        }
    }

    static func normalize(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value.isEmpty ? nil : value
    }

    /// WebUI only knows "zh-tw" / "zh-cn" (it maps both to whisper "zh" and runs OpenCC s2twp / t2s);
    /// other values are passed straight to whisper-server. So:
    ///   zh-tw, auto-tw → zh-tw;  zh-cn, auto-cn → zh-cn;  en → en (best effort, no OpenCC on the server).
    /// Auto is not sent as "auto" because the WebUI would skip its script conversion; local
    /// TranscriptFormatter still applies the app's own OpenCC / numerals / polish afterwards.
    static func webuiLanguage(forMode mode: String) -> String {
        switch mode {
        case "en": return "en"
        case "zh-cn", "auto-cn": return "zh-cn"
        default: return "zh-tw"
        }
    }
}

final class RemoteWhisperEngine: ASREngine {
    let kind: ASREngineKind = .remoteWhisper
    private(set) var state: ASREngineState = .notLoaded
    let endpoint: String
    let target: RemoteASRTarget
    private let client = BackendClient()
    private let lock = NSLock()
    private var pcm = Data()
    private var language = "zh-tw"
    private var openAILanguage: String?
    private var sessionID = 0
    private var task: Task<Void, Never>?

    private static let sampleRate = 16_000
    /// Same guard as AudioRecorder.stopAndMakeWav: under ~1 s of audio is not worth a round trip.
    private static let minimumPCMBytes = sampleRate * MemoryLayout<Int16>.size

    init(endpoint: String = RemoteWhisperSettings.selectedEndpoint) {
        self.endpoint = endpoint
        self.target = RemoteWhisperSettings.target(for: endpoint)
    }

    func load(completion: @escaping (ASREngineState) -> Void) {
        state = .loading
        guard !endpoint.isEmpty else {
            state = .failed("no remote endpoint configured ([localapp.backend-endpoint].remote_endpoint)")
            completion(state)
            return
        }
        Self.checkHealth(target: target) { [weak self] ok, detail in
            guard let self else { return }
            self.state = ok ? .ready : .failed(detail)
            Logger.shared.log("Remote ASR health: endpoint=\(self.endpoint), protocol=\(self.target.protocolKind.rawValue), "
                + "model=\(self.target.model), ok=\(ok), detail=\(detail)")
            completion(self.state)
        }
    }

    /// `language` here is the app's chinese-mode value (zh-tw / zh-cn / en / auto-tw / auto-cn).
    func startSession(language: String, onUpdate: @escaping (String) -> Void) {
        lock.lock()
        sessionID += 1
        pcm = Data()
        self.language = RemoteWhisperSettings.webuiLanguage(forMode: language)
        self.openAILanguage = RemoteWhisperSettings.openAILanguage(forMode: language)
        lock.unlock()
    }

    func feed(_ data: Data) {
        lock.lock()
        pcm.append(data)
        lock.unlock()
    }

    func finish(completion: @escaping (String) -> Void) {
        lock.lock()
        let recorded = pcm
        pcm = Data()
        let language = self.language
        let openAILanguage = self.openAILanguage
        let session = sessionID
        lock.unlock()

        guard recorded.count > Self.minimumPCMBytes else {
            Logger.shared.log("Remote Whisper skipped: recording too short, pcm_bytes=\(recorded.count)")
            completion("")
            return
        }
        let wav = Self.makeWav(pcm: recorded, sampleRate: Self.sampleRate)
        let target = target
        let client = client
        task = Task { [weak self] in
            var text = ""
            do {
                text = try await client.transcribe(wavData: wav, target: target,
                                                   webuiLanguage: language, openAILanguage: openAILanguage)
                text = Self.flattenSegments(text)
            } catch {
                Logger.shared.log("Remote ASR failed: endpoint=\(target.endpoint), error=\(error.localizedDescription)")
            }
            guard let self else { return }
            if !self.isCurrent(session) || Task.isCancelled { return }
            completion(text)
        }
    }

    private func isCurrent(_ session: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return session == sessionID
    }

    func cancel() {
        lock.lock()
        sessionID += 1
        pcm = Data()
        lock.unlock()
        task?.cancel()
        task = nil
    }

    /// webui-ime: GET {endpoint}/api/health. openai: GET {endpoint}/v1/models (must be a JSON model list).
    static func checkHealth(target: RemoteASRTarget, completion: @escaping (Bool, String) -> Void) {
        let path = target.protocolKind == .openAITranscriptions ? "/v1/models" : "/api/health"
        guard let url = URL(string: target.endpoint + path) else {
            completion(false, "invalid endpoint \(target.endpoint)")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        BackendClient.applyAuth(target: target, to: &request)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(false, "unreachable: \(error.localizedDescription)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                completion(false, "\(path) status=\(status)")
                return
            }
            if target.protocolKind == .openAITranscriptions, BackendClient.parseOpenAIModelIDs(data ?? Data()) == nil {
                completion(false, "\(path) is not an OpenAI model list")
                return
            }
            completion(true, "\(path) status=\(status)")
        }.resume()
    }

    /// Some models (e.g. VibeVoice-ASR) return a JSON array of segments as the text.
    /// Join their "Content" fields, skipping bracketed tags like [Silence].
    static func flattenSegments(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("["), let d = t.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return raw }
        let parts = arr.compactMap { seg -> String? in
            guard let c = (seg["Content"] ?? seg["content"] ?? seg["text"]) as? String else { return nil }
            let s = c.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty || (s.hasPrefix("[") && s.hasSuffix("]")) { return nil }
            return s
        }
        return parts.isEmpty && !arr.isEmpty ? "" : parts.joined(separator: " ")
    }

    static func makeWav(pcm: Data, sampleRate: Int) -> Data {
        var data = Data()
        data.appendString("RIFF")
        data.appendLittleEndian(UInt32(36 + pcm.count))
        data.appendString("WAVE")
        data.appendString("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))           // PCM
        data.appendLittleEndian(UInt16(1))           // mono
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * 2))
        data.appendLittleEndian(UInt16(2))           // block align
        data.appendLittleEndian(UInt16(16))          // bits per sample
        data.appendString("data")
        data.appendLittleEndian(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
