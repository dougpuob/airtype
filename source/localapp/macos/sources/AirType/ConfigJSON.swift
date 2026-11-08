import Foundation

/// Nested JSON document matching the shared AirType config shape used by localapp + WebUI.
enum ConfigJSON {
    struct Document: Codable {
        var localapp: LocalApp?
        var webui: WebUI?

        struct LocalApp: Codable {
            var chineseMode: ModeBox?
            var backendEndpoint: Backend?
            var microphone: Microphone?
            var floatingDialog: Floating?
            var recording: Recording?
            var obsidian: Obsidian?
            var localWhisper: LocalWhisper?
            var remoteAsr: [RemoteASR]?
            var defaultRemoteAsrName: String?

            enum CodingKeys: String, CodingKey {
                case chineseMode = "chinese-mode"
                case backendEndpoint = "backend-endpoint"
                case microphone
                case floatingDialog = "floating-dialog"
                case recording
                case obsidian
                case localWhisper = "local-whisper"
                case remoteAsr = "remote-asr"
                case defaultRemoteAsrName = "default-remote-asr-name"
            }
        }

        struct ModeBox: Codable { var mode: String? }
        struct Backend: Codable {
            var mode: String?
            var localEndpoint: String?
            var remoteEndpoint: String?
            enum CodingKeys: String, CodingKey {
                case mode
                case localEndpoint = "local_endpoint"
                case remoteEndpoint = "remote_endpoint"
            }
        }
        struct Microphone: Codable {
            var selectedDeviceName: String?
            var mode: String?
            var alwaysOnTimeoutMinutes: Int?
            var preRollSeconds: Double?
            enum CodingKeys: String, CodingKey {
                case selectedDeviceName = "selected_device_name"
                case mode
                case alwaysOnTimeoutMinutes = "always_on_timeout_minutes"
                case preRollSeconds = "pre_roll_seconds"
            }
        }
        struct Floating: Codable {
            var positionXRatio: Double?
            var positionYRatio: Double?
            var moveLock: Bool?
            enum CodingKeys: String, CodingKey {
                case positionXRatio = "position_x_ratio"
                case positionYRatio = "position_y_ratio"
                case moveLock = "move_lock"
            }
        }
        struct Recording: Codable {
            var hotkeyPressCount: String?
            var playCues: Bool?
            enum CodingKeys: String, CodingKey {
                case hotkeyPressCount = "hotkey_press_count"
                case playCues = "play_cues"
            }
        }
        struct Obsidian: Codable {
            var vaultPath: String?
            var defaultFolder: String?
            enum CodingKeys: String, CodingKey {
                case vaultPath = "vault_path"
                case defaultFolder = "default_folder"
            }
        }
        struct LocalWhisper: Codable {
            var enabled: Bool?
            var serverBin: String?
            var serverArgs: String?
            var host: String?
            var port: Int?
            var maxThreads: Int?
            var maxGpu: Int?
            var modelDir: String?
            var modelFilename: String?
            var language: String?
            var vocabularyPrompt: String?
            var noTimestamps: Bool?
            var noLanguageSymbol: Bool?
            var beam: Int?
            var temperature: Double?
            enum CodingKeys: String, CodingKey {
                case enabled
                case serverBin = "server_bin"
                case serverArgs = "server_args"
                case host, port
                case maxThreads = "max_threads"
                case maxGpu = "max_gpu"
                case modelDir = "model_dir"
                case modelFilename = "model_filename"
                case language
                case vocabularyPrompt = "vocabulary_prompt"
                case noTimestamps = "no_timestamps"
                case noLanguageSymbol = "no_language_symbol"
                case beam, temperature
            }
        }
        struct RemoteASR: Codable {
            var name: String?
            var endpoint: String?
            var protocolName: String?
            var model: String?
            var apiKey: String?
            enum CodingKeys: String, CodingKey {
                case name, endpoint, model
                case protocolName = "protocol"
                case apiKey = "api_key"
            }
        }

        struct WebUI: Codable {
            var storage: Storage?
            var auth: Auth?
            var whisperServer: [WhisperServer]?
            var llmServer: [LLMServer]?
            var defaultLlmServerName: String?
            var defaultWhisperServerName: String?
            var ytDlp: YtDlp?
            var ime: Ime?
            var obsidian: WebObsidian?
            var webToMarkdown: WebToMarkdown?
            var immich: Immich?
            var capturePost: CapturePost?
            // Preserve unknown webui keys by round-tripping via extra bag if needed later.

            enum CodingKeys: String, CodingKey {
                case storage, auth
                case whisperServer = "whisper-server"
                case llmServer = "llm-server"
                case defaultLlmServerName = "default-llm-server-name"
                case defaultWhisperServerName = "default-whisper-server-name"
                case ytDlp = "yt-dlp"
                case ime
                case obsidian
                case webToMarkdown = "web-to-markdown"
                case immich
                case capturePost = "capture-post"
            }
        }

        struct Storage: Codable {
            var dataDir: String?
            enum CodingKeys: String, CodingKey { case dataDir = "data_dir" }
        }
        struct Auth: Codable {
            var enabled: Bool?
            var username: String?
            var password: String?
            var sessionDays: Int?
            enum CodingKeys: String, CodingKey {
                case enabled, username, password
                case sessionDays = "session_days"
            }
        }
        struct WhisperServer: Codable {
            var name: String?
            var remoteEndpoint: String?
            var temperature: Double?
            var beam: Int?
            var language: String?
            enum CodingKeys: String, CodingKey {
                case name, temperature, beam, language
                case remoteEndpoint = "remote_endpoint"
            }
        }
        struct LLMServer: Codable {
            var name: String?
            var provider: String?
            var endpoint: String?
            var apiKey: String?
            var models: [String]?
            var selectedModel: String?
            var contextLength: Int?
            var temperature: Double?
            var thinking: Bool?
            var disableThinking: Bool? // legacy import only
            var system: String?
            enum CodingKeys: String, CodingKey {
                case name, provider, endpoint, models, temperature, thinking, system
                case apiKey = "api_key"
                case selectedModel = "selected-model"
                case contextLength
                case disableThinking = "disable_thinking"
            }
        }
        struct YtDlp: Codable {
            var cookies: String?
            var cookiesFromBrowser: String?
            enum CodingKeys: String, CodingKey {
                case cookies
                case cookiesFromBrowser = "cookies_from_browser"
            }
        }
        struct Ime: Codable { var correctionEnabled: Bool?
            enum CodingKeys: String, CodingKey { case correctionEnabled = "correction_enabled" }
        }
        struct WebObsidian: Codable {
            var vaultName: String?
            var defaultFolder: String?
            enum CodingKeys: String, CodingKey {
                case vaultName = "vault_name"
                case defaultFolder = "default_folder"
            }
        }
        struct WebToMarkdown: Codable {
            var apiKey: String?
            var timeoutSeconds: Int?
            var downloadMaxMb: Int?
            enum CodingKeys: String, CodingKey {
                case apiKey = "api_key"
                case timeoutSeconds = "timeout_seconds"
                case downloadMaxMb = "download_max_mb"
            }
        }
        struct Immich: Codable {
            var serverURL: String?
            var apiKey: String?
            var createAlbum: Bool?
            enum CodingKeys: String, CodingKey {
                case serverURL = "server_url"
                case apiKey = "api_key"
                case createAlbum = "create_album"
            }
        }
        struct CapturePost: Codable {
            var aiTitleEnabled: Bool?
            var titleSystemPrompt: String?
            var thinkingSteps: [String]?
            var tagsThinkingLevel: String?
            enum CodingKeys: String, CodingKey {
                case aiTitleEnabled = "ai_title_enabled"
                case titleSystemPrompt = "title_system_prompt"
                case thinkingSteps = "thinking_steps"
                case tagsThinkingLevel = "tags_thinking_level"
            }
        }
    }

    static func encode(_ config: AirTypeConfig) throws -> Data {
        let doc = document(from: config)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(doc)
    }

    static func decode(_ data: Data) throws -> AirTypeConfig {
        let doc = try JSONDecoder().decode(Document.self, from: data)
        return config(from: doc)
    }

    static func document(from config: AirTypeConfig) -> Document {
        var doc = Document()
        doc.localapp = .init(
            chineseMode: .init(mode: config.chineseMode.mode),
            backendEndpoint: .init(
                mode: config.backend.mode,
                localEndpoint: config.backend.localEndpoint,
                remoteEndpoint: config.backend.remoteEndpoint
            ),
            microphone: .init(
                selectedDeviceName: config.microphone.selectedDeviceName,
                mode: config.microphone.mode,
                alwaysOnTimeoutMinutes: config.microphone.alwaysOnTimeoutMinutes,
                preRollSeconds: config.microphone.preRollSeconds
            ),
            floatingDialog: .init(
                positionXRatio: config.floatingDialog.positionXRatio,
                positionYRatio: config.floatingDialog.positionYRatio,
                moveLock: config.floatingDialog.moveLock
            ),
            recording: .init(
                hotkeyPressCount: config.recording.hotkeyPressCount,
                playCues: config.recording.playCues
            ),
            obsidian: .init(
                vaultPath: config.obsidian.vaultPath,
                defaultFolder: config.obsidian.defaultFolder
            ),
            localWhisper: .init(
                enabled: config.localWhisper.enabled,
                serverBin: config.localWhisper.serverBin,
                serverArgs: config.localWhisper.serverArgs,
                host: config.localWhisper.host,
                port: config.localWhisper.port,
                maxThreads: config.localWhisper.maxThreads,
                maxGpu: config.localWhisper.maxGpu,
                modelDir: config.localWhisper.modelDir.isEmpty ? "~/.airtype/models/whisper" : config.localWhisper.modelDir,
                modelFilename: config.localWhisper.modelFilename,
                language: config.localWhisper.language,
                vocabularyPrompt: config.localWhisper.vocabularyPrompt,
                noTimestamps: config.localWhisper.noTimestamps,
                noLanguageSymbol: config.localWhisper.noLanguageSymbol,
                beam: config.localWhisper.beam,
                temperature: config.localWhisper.temperature
            ),
            remoteAsr: (config.remoteASRProfiles.isEmpty ? [config.remoteASR] : config.remoteASRProfiles).map {
                .init(name: $0.name, endpoint: $0.endpoint, protocolName: $0.protocolName, model: $0.model, apiKey: $0.apiKey)
            },
            defaultRemoteAsrName: config.selectedRemoteASRName.isEmpty ? config.remoteASR.name : config.selectedRemoteASRName
        )

        let whisperProfiles = config.webui.whisperServers.isEmpty ? [config.webui.whisper] : config.webui.whisperServers
        let llmProfiles = config.webui.llmServers.isEmpty ? [config.webui.llm] : config.webui.llmServers
        doc.webui = .init(
            storage: .init(dataDir: "~/.airtype/data"),
            auth: .init(
                enabled: config.webui.auth.enabled,
                username: config.webui.auth.username,
                password: config.webui.auth.password,
                sessionDays: 14
            ),
            whisperServer: whisperProfiles.map {
                .init(
                    name: $0.name,
                    remoteEndpoint: $0.remoteEndpoint,
                    temperature: $0.temperature,
                    beam: $0.beam,
                    language: $0.language
                )
            },
            llmServer: llmProfiles.map {
                .init(
                    name: $0.name,
                    provider: $0.provider,
                    endpoint: $0.endpoint,
                    apiKey: $0.apiKey,
                    models: $0.models,
                    selectedModel: $0.selectedModel,
                    contextLength: $0.contextLength,
                    temperature: $0.temperature,
                    thinking: $0.thinking,
                    disableThinking: nil,
                    system: $0.system
                )
            },
            defaultLlmServerName: config.webui.selectedServerName,
            defaultWhisperServerName: config.webui.selectedWhisperServerName.isEmpty ? config.webui.whisper.name : config.webui.selectedWhisperServerName,
            ytDlp: nil,
            ime: nil,
            obsidian: nil,
            webToMarkdown: nil,
            immich: nil,
            capturePost: nil
        )
        return doc
    }

    static func config(from doc: Document) -> AirTypeConfig {
        var config = AirTypeConfig()
        if let la = doc.localapp {
            if let mode = la.chineseMode?.mode { config.chineseMode.mode = mode }
            if let b = la.backendEndpoint {
                if let mode = b.mode { config.backend.mode = mode }
                if let v = b.localEndpoint { config.backend.localEndpoint = v }
                if let v = b.remoteEndpoint { config.backend.remoteEndpoint = v }
            }
            if let m = la.microphone {
                if let v = m.selectedDeviceName { config.microphone.selectedDeviceName = v }
                if let v = m.mode { config.microphone.mode = v }
                if let v = m.alwaysOnTimeoutMinutes { config.microphone.alwaysOnTimeoutMinutes = v }
                if let v = m.preRollSeconds { config.microphone.preRollSeconds = v }
            }
            if let f = la.floatingDialog {
                if let v = f.positionXRatio { config.floatingDialog.positionXRatio = v }
                if let v = f.positionYRatio { config.floatingDialog.positionYRatio = v }
                if let v = f.moveLock { config.floatingDialog.moveLock = v }
            }
            if let r = la.recording {
                if let v = r.hotkeyPressCount { config.recording.hotkeyPressCount = v }
                if let v = r.playCues { config.recording.playCues = v }
            }
            if let o = la.obsidian {
                if let v = o.vaultPath { config.obsidian.vaultPath = v }
                if let v = o.defaultFolder { config.obsidian.defaultFolder = v }
            }
            if let w = la.localWhisper {
                applyLocalWhisper(w, to: &config.localWhisper)
            }
            if let profiles = la.remoteAsr, !profiles.isEmpty {
                config.remoteASRProfiles = profiles.map {
                    RemoteASRConfig(
                        name: $0.name ?? "default",
                        endpoint: $0.endpoint ?? "",
                        protocolName: $0.protocolName ?? "webui-ime",
                        model: $0.model ?? "",
                        apiKey: $0.apiKey ?? ""
                    )
                }
                let selected = la.defaultRemoteAsrName ?? config.remoteASRProfiles[0].name
                config.selectedRemoteASRName = selected
                config.remoteASR = config.remoteASRProfiles.first(where: { $0.name == selected }) ?? config.remoteASRProfiles[0]
            }
        }
        if let wu = doc.webui {
            if let auth = wu.auth {
                if let v = auth.enabled { config.webui.auth.enabled = v }
                if let v = auth.username { config.webui.auth.username = v }
                if let v = auth.password { config.webui.auth.password = v }
            }
            if let profiles = wu.whisperServer, !profiles.isEmpty {
                config.webui.whisperServers = profiles.map {
                    WhisperServerConfig(
                        name: $0.name ?? "default",
                        remoteEndpoint: $0.remoteEndpoint ?? "",
                        temperature: $0.temperature ?? 0,
                        beam: $0.beam ?? 5,
                        language: $0.language ?? "zh-tw"
                    )
                }
                let selected = wu.defaultWhisperServerName ?? config.webui.whisperServers[0].name
                config.webui.selectedWhisperServerName = selected
                config.webui.whisper = config.webui.whisperServers.first(where: { $0.name == selected }) ?? config.webui.whisperServers[0]
            }
            if let profiles = wu.llmServer, !profiles.isEmpty {
                config.webui.llmServers = profiles.map { llm in
                    let thinking: Bool
                    if let t = llm.thinking {
                        thinking = t
                    } else if let disabled = llm.disableThinking {
                        thinking = !disabled
                    } else {
                        thinking = false
                    }
                    return LLMServerConfig(
                        name: llm.name ?? "default",
                        provider: llm.provider ?? "llama.cpp",
                        endpoint: llm.endpoint ?? "http://127.0.0.1:8080",
                        apiKey: llm.apiKey ?? "",
                        models: llm.models ?? [],
                        selectedModel: llm.selectedModel ?? "",
                        contextLength: llm.contextLength ?? 8192,
                        temperature: llm.temperature ?? 0.4,
                        thinking: thinking,
                        system: llm.system ?? "Summarize and answer questions using the transcript as the source of truth."
                    )
                }
                let selected = wu.defaultLlmServerName ?? config.webui.llmServers[0].name
                config.webui.selectedServerName = selected
                config.webui.llm = config.webui.llmServers.first(where: { $0.name == selected }) ?? config.webui.llmServers[0]
                config.webui.selectedModelName = config.webui.llm.selectedModel
            }
        }
        return config
    }

    private static func applyLocalWhisper(_ w: Document.LocalWhisper, to target: inout LocalWhisperServiceConfig) {
        if let v = w.enabled { target.enabled = v }
        if let v = w.serverBin { target.serverBin = v }
        if let v = w.serverArgs { target.serverArgs = v }
        if let v = w.host { target.host = v }
        if let v = w.port { target.port = v }
        if let v = w.maxThreads { target.maxThreads = v }
        if let v = w.maxGpu { target.maxGpu = v }
        if let v = w.modelDir { target.modelDir = v }
        if let v = w.modelFilename { target.modelFilename = v }
        if let v = w.language { target.language = v }
        if let v = w.vocabularyPrompt { target.vocabularyPrompt = v }
        if let v = w.noTimestamps { target.noTimestamps = v }
        if let v = w.noLanguageSymbol { target.noLanguageSymbol = v }
        if let v = w.beam { target.beam = v }
        if let v = w.temperature { target.temperature = v }
    }
}
