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
    /// Whisper profile beam. Nil keeps the WebUI IME default.
    var beam: Int? = nil
}

/// One named profile from ASR Endpoints or ASR Endpoints (Whisper).
struct RemoteProfileChoice: Equatable {
    enum Kind: String { case asr, whisper }
    var kind: Kind
    var name: String
    var title: String
    var id: String { "\(kind.rawValue):\(name)" }
}

/// Remote endpoint choices + auth, populated by the coordinator from the config
/// ([localapp.backend-endpoint] remote_endpoint / local_endpoint, [webui.auth]) and UserDefaults.
/// Read and written on the main thread only.
enum RemoteWhisperSettings {
    /// Env override: AIRTYPE_REMOTE_ENDPOINT=https://host replaces the selected profile's endpoint.
    static var envEndpoint: String? {
        let raw = ProcessInfo.processInfo.environment["AIRTYPE_REMOTE_ENDPOINT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : normalize(raw)
    }

    static var choices: [RemoteProfileChoice] = []
    static var selectedChoiceID = ""
    static var auth = WebUIAuthConfig()
    private static var asrProfiles: [RemoteASRConfig] = []
    private static var whisperProfiles: [WhisperServerConfig] = []

    /// Profile lists from config. The active choice is `default-remote-profile`, not a remembered URL.
    static func configure(config: AirTypeConfig) {
        asrProfiles = config.remoteASRProfiles.isEmpty ? [config.remoteASR] : config.remoteASRProfiles
        whisperProfiles = config.webui.whisperServers.isEmpty ? [config.webui.whisper] : config.webui.whisperServers
        let asrNames = Set(asrProfiles.map(\.name))
        var built = asrProfiles.map { RemoteProfileChoice(kind: .asr, name: $0.name, title: $0.name) }
        for profile in whisperProfiles {
            let title = asrNames.contains(profile.name) ? "\(profile.name) (Whisper)" : profile.name
            built.append(RemoteProfileChoice(kind: .whisper, name: profile.name, title: title))
        }
        choices = built
        auth = config.webui.auth
        let resolved = resolvedID(in: config)
        selectedChoiceID = choices.contains(where: { $0.id == resolved }) ? resolved : (choices.first?.id ?? resolved)
    }

    static var selectedChoice: RemoteProfileChoice? {
        choices.first { $0.id == selectedChoiceID } ?? choices.first
    }

    static var selectedTarget: RemoteASRTarget {
        guard let choice = selectedChoice else {
            return RemoteASRTarget(endpoint: "", protocolKind: .webuiIME, model: "", apiKey: "", auth: auth)
        }
        var target = target(for: choice)
        if let env = envEndpoint { target.endpoint = env }
        return target
    }

    static var selectedEndpoint: String { selectedTarget.endpoint }

    static func target(for choice: RemoteProfileChoice) -> RemoteASRTarget {
        switch choice.kind {
        case .asr:
            let profile = asrProfiles.first { $0.name == choice.name } ?? RemoteASRConfig(name: choice.name)
            return RemoteASRTarget(
                endpoint: normalize(profile.endpoint) ?? "",
                protocolKind: RemoteASRProtocol(rawValue: profile.protocolName) ?? .webuiIME,
                model: profile.model,
                apiKey: profile.apiKey,
                auth: auth
            )
        case .whisper:
            let profile = whisperProfiles.first { $0.name == choice.name } ?? WhisperServerConfig(name: choice.name)
            return RemoteASRTarget(
                endpoint: normalize(profile.remoteEndpoint) ?? "",
                protocolKind: .webuiIME,
                model: "",
                apiKey: "",
                auth: auth,
                beam: profile.beam
            )
        }
    }

    static func resolvedID(in config: AirTypeConfig) -> String {
        if let parsed = parse(config.defaultRemoteProfile),
           (parsed.kind == .asr && asrProfiles.contains { $0.name == parsed.name })
            || (parsed.kind == .whisper && whisperProfiles.contains { $0.name == parsed.name }) {
            return parsed.id
        }
        let asrName = config.selectedRemoteASRName.isEmpty ? config.remoteASR.name : config.selectedRemoteASRName
        if asrProfiles.contains(where: { $0.name == asrName && normalize($0.endpoint) != nil }) {
            return "asr:\(asrName)"
        }
        let whisperName = config.webui.selectedWhisperServerName.isEmpty ? config.webui.whisper.name : config.webui.selectedWhisperServerName
        if whisperProfiles.contains(where: { $0.name == whisperName && normalize($0.remoteEndpoint) != nil }) {
            return "whisper:\(whisperName)"
        }
        return "asr:\(asrName)"
    }

    static func parse(_ raw: String) -> RemoteProfileChoice? {
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = RemoteProfileChoice.Kind(rawValue: parts[0]), !parts[1].isEmpty else { return nil }
        return RemoteProfileChoice(kind: kind, name: parts[1], title: parts[1])
    }

    /// Point the active ASR or Whisper profile at `id` (`asr:name` or `whisper:name`).
    static func activate(_ id: String, in config: inout AirTypeConfig) {
        config.defaultRemoteProfile = id
        guard let choice = parse(id) else { return }
        switch choice.kind {
        case .asr:
            guard let profile = config.remoteASRProfiles.first(where: { $0.name == choice.name }) else { return }
            config.selectedRemoteASRName = profile.name
            config.remoteASR = profile
        case .whisper:
            guard let profile = config.webui.whisperServers.first(where: { $0.name == choice.name }) else { return }
            config.webui.selectedWhisperServerName = profile.name
            config.webui.whisper = profile
        }
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
        let selected = RemoteWhisperSettings.selectedTarget
        if endpoint.isEmpty || endpoint == selected.endpoint {
            self.endpoint = selected.endpoint
            self.target = selected
        } else {
            self.endpoint = endpoint
            self.target = RemoteASRTarget(endpoint: endpoint, protocolKind: .webuiIME, model: "", apiKey: "", auth: RemoteWhisperSettings.auth)
        }
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
