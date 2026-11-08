import Foundation

/// Shared surface of the local ASR engines (Nemotron streaming, Qwen3-ASR VAD+re-decode).
enum ASREngineState: Equatable {
    case notLoaded
    case loading
    case ready
    case failed(String)
}

enum ASREngineKind: String, CaseIterable {
    case qwen3 = "qwen3"
    case qwen3Large = "qwen3-1.7b"
    case funasrNano = "funasr-nano"
    case senseVoice = "sensevoice"
    case paraformer = "paraformer"
    case zipformer = "zipformer"
    case nemotron = "nemotron"
    /// Remote Whisper via the AirType WebUI (merged from localapp). Not a local model.
    case remoteWhisper = "remote-whisper"

    var title: String {
        switch self {
        case .qwen3: return "Qwen3-ASR 0.6B"
        case .qwen3Large: return "Qwen3-ASR 1.7B"
        case .funasrNano: return "Fun-ASR-Nano 2512"
        case .senseVoice: return "SenseVoice Multilingual"
        case .paraformer: return "Paraformer ZH-EN Streaming"
        case .zipformer: return "Zipformer ZH-EN"
        case .nemotron: return "Nemotron 3.5 Streaming"
        case .remoteWhisper: return "Remote"
        }
    }

    var shortName: String {
        switch self {
        case .qwen3: return "Qwen3-ASR 0.6B"
        case .qwen3Large: return "Qwen3-ASR 1.7B"
        case .funasrNano: return "Fun-ASR-Nano"
        case .senseVoice: return "SenseVoice"
        case .paraformer: return "Paraformer"
        case .zipformer: return "Zipformer"
        case .nemotron: return "Nemotron"
        case .remoteWhisper: return "Remote ASR"
        }
    }

    var isRemote: Bool { self == .remoteWhisper }

    /// Local (sherpa-onnx, in-process) models shown under ASR Engine ▸ Local.
    static let localCases: [ASREngineKind] = [
        .qwen3, .qwen3Large, .funasrNano, .senseVoice, .paraformer, .zipformer, .nemotron,
    ]

    /// Two-level selection persisted in UserDefaults:
    ///   asrBackend    = "local" | "remote"
    ///   asrLocalModel = qwen3 | qwen3-1.7b | funasr-nano | sensevoice | paraformer | zipformer | nemotron
    ///                   (legacy key "asrEngine" is still read)
    ///   asrRemoteEndpoint (see RemoteWhisperSettings)
    static let defaultsKey = "asrEngine"            // legacy single-level key (pre-merge)
    static let localModelDefaultsKey = "asrLocalModel"
    static let backendDefaultsKey = "asrBackend"

    /// Local model to use when Backend = Local (remembered even while Remote is selected).
    static var storedLocalModel: ASREngineKind {
        for key in [localModelDefaultsKey, defaultsKey] {
            if let stored = UserDefaults.standard.string(forKey: key),
               let kind = ASREngineKind(rawValue: stored), !kind.isRemote {
                return kind
            }
        }
        return .qwen3
    }

    static var storedBackendIsRemote: Bool {
        UserDefaults.standard.string(forKey: backendDefaultsKey) == "remote"
    }

    static func persistLocalModel(_ kind: ASREngineKind) {
        guard !kind.isRemote else { return }
        UserDefaults.standard.set(kind.rawValue, forKey: localModelDefaultsKey)
        UserDefaults.standard.set(kind.rawValue, forKey: defaultsKey)
    }

    static func persistBackend(remote: Bool) {
        UserDefaults.standard.set(remote ? "remote" : "local", forKey: backendDefaultsKey)
    }

    /// Selection order: AIRTYPE_ASR_ENGINE env var (a local model or "remote") > menu choice > qwen3.
    static var current: ASREngineKind {
        if let env = ProcessInfo.processInfo.environment["AIRTYPE_ASR_ENGINE"], let kind = ASREngineKind(alias: env) {
            return kind
        }
        return storedBackendIsRemote ? .remoteWhisper : storedLocalModel
    }

    /// Accepts "qwen3", "qwen3-1.7b" / "qwen3-large", "nemotron", "funasr-nano" / "funasr",
    /// "sensevoice" / "sense-voice", "paraformer", "zipformer" / "zipformer-ctc", "remote".
    init?(alias: String) {
        let key = alias.lowercased().replacingOccurrences(of: "_", with: "-")
        switch key {
        case "qwen3", "qwen3-asr", "qwen3-0.6b", "qwen3-asr-0.6b": self = .qwen3
        case "qwen3-1.7b", "qwen3-asr-1.7b", "qwen3-large", "qwen3-17b": self = .qwen3Large
        case "nemotron": self = .nemotron
        case "funasr-nano", "funasr", "fun-asr-nano", "fun-asr", "funasrnano": self = .funasrNano
        case "sensevoice", "sense-voice", "sense": self = .senseVoice
        case "paraformer", "paraformer-zh": self = .paraformer
        case "zipformer", "zipformer-ctc", "zipformer-zh": self = .zipformer
        case "remote", "remote-whisper", "whisper", "webui": self = .remoteWhisper
        default: return nil
        }
    }

    func makeEngine() -> ASREngine {
        switch self {
        case .qwen3: return Qwen3ASREngine(model: .qwen3)
        case .qwen3Large: return Qwen3ASREngine(model: .qwen3Large)
        case .funasrNano: return Qwen3ASREngine(model: .funasrNano)
        case .senseVoice: return Qwen3ASREngine(model: .senseVoice)
        case .paraformer: return ParaformerStreamingEngine()
        case .zipformer: return Qwen3ASREngine(model: .zipformer)
        case .nemotron: return NemotronStreamingEngine()
        case .remoteWhisper: return RemoteWhisperEngine()
        }
    }
}

protocol ASREngine: AnyObject {
    var kind: ASREngineKind { get }
    var state: ASREngineState { get }
    func load(completion: @escaping (ASREngineState) -> Void)
    func startSession(language: String, onUpdate: @escaping (String) -> Void)
    func feed(_ pcm: Data)
    func finish(completion: @escaping (String) -> Void)
    func cancel()
}
