import Foundation

struct AirTypeConfig {
    var chineseMode = ChineseMode()
    var backend = BackendConfig()
    /// Active Remote ASR profile (the one the engine uses). Mirrors the entry named `selectedRemoteASRName`.
    var remoteASR = RemoteASRConfig()
    /// All `[[localapp.remote-asr]]` profiles (a legacy single `[localapp.remote-asr]` table loads as one profile).
    var remoteASRProfiles: [RemoteASRConfig] = []
    /// `[localapp] default-remote-asr-name`.
    var selectedRemoteASRName = ""
    var microphone = MicrophoneConfig()
    var floatingDialog = FloatingDialogConfig()
    var recording = RecordingConfig()
    var obsidian = ObsidianConfig()
    /// [localapp.local-whisper]: self-hosted whisper-server on this Mac.
    var localWhisper = LocalWhisperServiceConfig()
    var webui = WebUIConfig()
}

struct LocalWhisperServiceConfig: Equatable {
    var enabled = false
    var serverBin = ""
    var serverArgs = ""
    var host = "127.0.0.1"
    var port = 8080
    var maxThreads = 4
    var maxGpu = 1
    var modelDir = "~/.airtype/models/whisper"
    var modelFilename = ""
    var language = "zh-tw"
    var vocabularyPrompt = ""
    var noTimestamps = true
    var noLanguageSymbol = true
    var beam = 5
    var temperature = 0.0
}

struct ChineseMode {
    var mode = "zh-tw"
}

struct BackendConfig {
    var mode = "local"
    var localEndpoint = "http://127.0.0.1:8003"
    var remoteEndpoint = ""

    var selectedEndpoint: String {
        if mode == "remote", !remoteEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return remoteEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return localEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// [[localapp.remote-asr]]: one named Remote ASR profile edited in Settings ▸ Endpoints ▸ ASR.
/// protocol: "webui-ime" (AirType WebUI /api/transcribe/ime) or "openai" (POST /v1/audio/transcriptions).
struct RemoteASRConfig: Equatable {
    var name = "default"
    var endpoint = ""
    var protocolName = "webui-ime"
    var model = ""
    var apiKey = ""
}

/// Field metadata exposed to the Settings window (mirrors the JSON schema sections).
enum ConfigFieldKind {
    case string, secret, int, number, bool, array
}

struct ConfigFieldDescriptor {
    let section: String
    let key: String
    let comment: String?
    let kind: ConfigFieldKind
    let options: [String]
}

struct ConfigSectionDescriptor {
    let group: String
    let name: String
    let fields: [ConfigFieldDescriptor]
}

struct MicrophoneConfig: Equatable {
    var selectedDeviceName = ""
    var mode = "on_demand"
    var alwaysOnTimeoutMinutes = 10
    var preRollSeconds = 2.0
}

/// Internal floating-pill placement (not shown in Settings). Dragging updates the ratios;
/// they are the fallback when the text insertion point cannot be resolved.
struct FloatingDialogConfig {
    var positionXRatio = 0.5
    var positionYRatio = 0.62
}

/// [localapp.recording]: hotkey gesture + optional start/end cues.
struct RecordingConfig {
    /// "single" (default) or "double" — how many exclusive Right Ctrl/Option presses start/stop.
    var hotkeyPressCount = "single"
    /// Which physical key(s) fire the gesture: right_ctrl / right_option / right_alt / right_command / auto.
    /// On macOS, right_option and right_alt are the same physical key; right_command is ⌘.
    var hotkeyTrigger = "auto"
    /// Quiet system sounds when capture actually starts / after capture stops.
    var playCues = true
}

/// [localapp.obsidian]: where the local app writes captured notes as Markdown files.
struct ObsidianConfig {
    /// Absolute path to the Obsidian vault root (or a folder inside it).
    var vaultPath = ""
    /// Optional subfolder under the vault. Empty = vault root.
    var defaultFolder = ""
}

struct WebUIConfig {
    /// Active whisper-server profile. Mirrors the entry named `selectedWhisperServerName`.
    var whisper = WhisperServerConfig()
    /// All `[[webui.whisper-server]]` profiles (a legacy single table loads as one profile).
    var whisperServers: [WhisperServerConfig] = []
    /// `[webui] default-whisper-server-name`.
    var selectedWhisperServerName = ""
    var auth = WebUIAuthConfig()
    var llm = LLMServerConfig()
    var llmServers: [LLMServerConfig] = []
    var selectedServerName = ""
    var selectedModelName = ""
}

struct LLMServerEntry {
    let name: String
    let provider: String
    let endpoint: String
    let apiKey: String
    let models: [String]
    let selectedModel: String
    let contextLength: Int
    let temperature: Double
    let thinking: Bool
    let system: String
}

struct WebUIAuthConfig {
    var enabled = false
    var username = "airtype"
    var password = ""
}

/// [[webui.whisper-server]]: where to reach a whisper server (local or remote). Self-host lives in LocalWhisperServiceConfig.
struct WhisperServerConfig: Equatable {
    var name = "default"
    var remoteEndpoint = ""
    var temperature = 0.0
    var beam = 5
    var language = "zh-tw"
}

struct LLMServerConfig: Equatable {
    var name: String
    var provider: String
    var endpoint: String
    var apiKey: String
    var models: [String]
    var selectedModel: String
    var contextLength: Int
    var temperature: Double
    var thinking: Bool
    var system: String

    init(
        name: String = "default",
        provider: String = "llama.cpp",
        endpoint: String = "http://127.0.0.1:8080",
        apiKey: String = "",
        models: [String] = [],
        selectedModel: String = "",
        contextLength: Int = 8192,
        temperature: Double = 0.4,
        thinking: Bool = false,
        system: String = "Summarize and answer questions using the transcript as the source of truth."
    ) {
        self.name = name
        self.provider = provider
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.models = models
        self.selectedModel = selectedModel
        self.contextLength = contextLength
        self.temperature = temperature
        self.thinking = thinking
        self.system = system
    }
}

final class ConfigStore: ObservableObject {
    @Published private(set) var config = AirTypeConfig()

    let projectRoot: URL?

    private var path: URL { Self.configPath }

    init() {
        projectRoot = Self.findProjectRoot()
        let migrateNotes = AirTypeHome.migrateIfNeeded()
        for note in migrateNotes {
            Logger.shared.log("Home migrate: \(note)")
        }
    }

    func load() throws {
        try Self.ensureConfigJSONExists()
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw ConfigStoreError.missingConfig(path.path)
        }
        guard var text = try? String(contentsOf: path, encoding: .utf8) else {
            throw ConfigStoreError.unreadableConfig(path.path)
        }
        AirTypeHome.rewriteLegacyPaths(in: &text)
        guard let data = text.data(using: .utf8) else {
            throw ConfigStoreError.unreadableConfig(path.path)
        }
        do {
            config = try ConfigJSON.decode(data)
        } catch {
            throw ConfigStoreError.unreadableConfig(path.path)
        }
        rewriteLegacyModelDirsInMemory()
        logLoadedConfig()
    }

    private func rewriteLegacyModelDirsInMemory() {
        let flat = "~/.airtype/models"
        let correct = "~/.airtype/models/whisper"
        if config.localWhisper.modelDir == flat || config.localWhisper.modelDir.hasSuffix("/.airtype/models") {
            config.localWhisper.modelDir = correct
        }
        // Mistaken double "whisper" segment from earlier UI/defaults.
        if config.localWhisper.modelDir == "~/.airtype/models/whisper/whisper"
            || config.localWhisper.modelDir.hasSuffix("/models/whisper/whisper") {
            config.localWhisper.modelDir = correct
        }
        if config.localWhisper.modelDir.contains(".airtype-experiment/models") {
            config.localWhisper.modelDir = config.localWhisper.modelDir.replacingOccurrences(
                of: ".airtype-experiment/models",
                with: ".airtype/models/asr"
            )
        }
    }

    private func logLoadedConfig() {
        Logger.shared.log("Loaded config: path=\(path.path), project_root=\(projectRoot?.path ?? "not found")")
        Logger.shared.log(
            "Config localapp.backend-endpoint: mode=\(config.backend.mode), "
            + "local_endpoint=\(config.backend.localEndpoint), "
            + "remote_endpoint=\(config.backend.remoteEndpoint), "
            + "selected_endpoint=\(config.backend.selectedEndpoint)"
        )
        Logger.shared.log(
            "Config localapp.microphone: mode=\(config.microphone.mode), "
            + "selected_device_name=\(config.microphone.selectedDeviceName.isEmpty ? "default" : config.microphone.selectedDeviceName), "
            + "always_on_timeout_minutes=\(config.microphone.alwaysOnTimeoutMinutes), "
            + "pre_roll_seconds=\(config.microphone.preRollSeconds)"
        )
        Logger.shared.log(
            "Config localapp: hotkey_trigger=\(config.recording.hotkeyTrigger); "
            + "chinese_mode=\(config.chineseMode.mode); "
            + "floating_dialog=(x=\(config.floatingDialog.positionXRatio), y=\(config.floatingDialog.positionYRatio))"
        )
        Logger.shared.log(
            "Config localapp.recording: hotkey_press_count=\(config.recording.hotkeyPressCount), "
            + "hotkey_trigger=\(config.recording.hotkeyTrigger), "
            + "play_cues=\(config.recording.playCues)"
        )
        Logger.shared.log(
            "Config localapp.obsidian: vault_path=\(config.obsidian.vaultPath.isEmpty ? "(empty)" : config.obsidian.vaultPath), "
            + "default_folder=\(config.obsidian.defaultFolder.isEmpty ? "(vault root)" : config.obsidian.defaultFolder)"
        )
        Logger.shared.log(
            "Config localapp.remote-asr: active=\(config.remoteASR.name), profiles=\(config.remoteASRProfiles.map(\.name).joined(separator: ",")), "
            + "endpoint=\(config.remoteASR.endpoint), protocol=\(config.remoteASR.protocolName), model=\(config.remoteASR.model)"
        )
        Logger.shared.log(
            "Config webui.whisper-server: active=\(config.webui.whisper.name), profiles=\(config.webui.whisperServers.map(\.name).joined(separator: ",")), "
            + "remote_endpoint=\(config.webui.whisper.remoteEndpoint)"
        )
        Logger.shared.log(
            "Config localapp.local-whisper: enabled=\(config.localWhisper.enabled), "
            + "server_bin=\(config.localWhisper.serverBin), model_dir=\(config.localWhisper.modelDir), "
            + "model_filename=\(config.localWhisper.modelFilename), language=\(config.localWhisper.language), "
            + "beam=\(config.localWhisper.beam), temperature=\(config.localWhisper.temperature)"
        )
        Logger.shared.log(
            "Config webui.auth: enabled=\(config.webui.auth.enabled), "
            + "username=\(config.webui.auth.username), "
            + "password_set=\(!config.webui.auth.password.isEmpty)"
        )
        Logger.shared.log(
            "Config webui.llm-server: selected_server=\(config.webui.selectedServerName), "
            + "active_name=\(config.webui.llm.name), "
            + "provider=\(config.webui.llm.provider), "
            + "endpoint=\(config.webui.llm.endpoint), "
            + "selected_model=\(config.webui.llm.selectedModel), "
            + "server_count=\(config.webui.llmServers.count)"
        )
    }

    var filePath: String { path.path }

    /// Settings window: replace the whole config and write it back to config.json.
    func replaceAndSave(_ newConfig: AirTypeConfig) {
        config = newConfig
        save()
        Logger.shared.log("Config saved from Settings window: path=\(path.path)")
    }

    static var sectionDescriptors: [ConfigSectionDescriptor] {
        schema.map { section in
            ConfigSectionDescriptor(group: section.group, name: section.name, fields: section.fields.map {
                ConfigFieldDescriptor(section: $0.section, key: $0.key, comment: $0.comment, kind: $0.kind, options: $0.options)
            })
        }
    }

    /// Plain field value; arrays are returned comma-separated.
    static func displayValue(section: String, key: String, in config: AirTypeConfig) -> String {
        guard let field = schema.first(where: { $0.name == section })?.fields.first(where: { $0.key == key }) else { return "" }
        return field.render(config)
    }

    /// Applies a plain value (arrays comma-separated) through the Settings field schema.
    static func apply(section: String, key: String, value: String, to config: inout AirTypeConfig) {
        guard let field = schema.first(where: { $0.name == section })?.fields.first(where: { $0.key == key }) else { return }
        field.apply(&config, value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func updateChineseMode(_ mode: String) {
        config.chineseMode.mode = Self.normalizeLanguage(mode)
        save()
    }

    func updateMicrophoneDeviceName(_ deviceName: String) {
        config.microphone.selectedDeviceName = deviceName
        save()
    }

    func updateMicrophoneMode(_ mode: String) {
        config.microphone.mode = Self.normalizeMicrophoneMode(mode)
        save()
    }

    func updatePreRollSeconds(_ seconds: Double) {
        config.microphone.preRollSeconds = Self.clamp(seconds, minimum: 0.0, maximum: 5.0)
        save()
    }

    func updateFloatingPosition(xRatio: Double, yRatio: Double) {
        config.floatingDialog.positionXRatio = Self.clamp(xRatio, minimum: 0.0, maximum: 1.0)
        config.floatingDialog.positionYRatio = Self.clamp(yRatio, minimum: 0.0, maximum: 1.0)
        save()
    }

    func updateLLMServer(_ serverName: String) {
        config.webui.selectedServerName = serverName
        if let match = config.webui.llmServers.first(where: { $0.name == serverName }) {
            config.webui.llm = match
            config.webui.selectedModelName = match.selectedModel
        }
        save()
    }

    func updateLLMModel(_ modelName: String) {
        config.webui.selectedModelName = modelName
        config.webui.llm.selectedModel = modelName
        syncActiveLLMServer()
        save()
    }

    func updateLLMSelection(serverName: String, modelName: String) {
        config.webui.selectedServerName = serverName
        config.webui.selectedModelName = modelName
        if let match = config.webui.llmServers.first(where: { $0.name == serverName }) {
            config.webui.llm = match
        }
        config.webui.llm.selectedModel = modelName
        syncActiveLLMServer()
        save()
    }

    func updateLLMServerModels(_ modelsByServer: [String: [String]]) {
        for (serverName, models) in modelsByServer {
            if let index = config.webui.llmServers.firstIndex(where: { $0.name == serverName }) {
                config.webui.llmServers[index].models = models
                if config.webui.llmServers[index].selectedModel.isEmpty, let first = models.first {
                    config.webui.llmServers[index].selectedModel = first
                }
            }
            if config.webui.llm.name == serverName {
                config.webui.llm.models = models
                if config.webui.llm.selectedModel.isEmpty, let first = models.first {
                    config.webui.llm.selectedModel = first
                    config.webui.selectedModelName = first
                }
            }
        }
        save()
    }

    func availableLLMServers() -> [LLMServerEntry] {
        let servers = config.webui.llmServers.isEmpty ? [config.webui.llm] : config.webui.llmServers
        return servers.map {
            LLMServerEntry(
                name: $0.name,
                provider: $0.provider,
                endpoint: $0.endpoint,
                apiKey: $0.apiKey,
                models: $0.models,
                selectedModel: $0.selectedModel,
                contextLength: $0.contextLength,
                temperature: $0.temperature,
                thinking: $0.thinking,
                system: $0.system
            )
        }
    }

    private func syncActiveLLMServer() {
        let serverName = config.webui.selectedServerName.isEmpty ? config.webui.llm.name : config.webui.selectedServerName
        config.webui.llm.name = serverName
        if let index = config.webui.llmServers.firstIndex(where: { $0.name == serverName }) {
            config.webui.llmServers[index] = config.webui.llm
        } else {
            config.webui.llmServers.append(config.webui.llm)
        }
    }

    private func save() {
        let jsonPath = AirTypeHome.configJSON
        try? FileManager.default.createDirectory(
            at: jsonPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            let data = try ConfigJSON.encode(config)
            try data.write(to: jsonPath, options: .atomic)
        } catch {
            Logger.shared.log("Could not write config.json: \(error)")
        }
    }

    private struct ConfigSectionSchema {
        let group: String
        let name: String
        let fields: [ConfigFieldSchema]
    }

    private struct ConfigFieldSchema {
        let section: String
        let key: String
        let comment: String?
        let apply: (inout AirTypeConfig, String) -> Void
        let render: (AirTypeConfig) -> String
        var kind: ConfigFieldKind = .string
        var options: [String] = []
    }

    private static let schema: [ConfigSectionSchema] = [
        ConfigSectionSchema(
            group: "Local App Settings",
            name: "localapp.chinese-mode",
            fields: [
                stringField("localapp.chinese-mode", "mode", comment: #"Options: "zh-tw", "zh-cn", "en", "auto-tw", "auto-cn""#,
                            options: ["zh-tw", "zh-cn", "en", "auto-tw", "auto-cn"],
                            apply: { $0.chineseMode.mode = normalizeLanguage($1) },
                            render: { $0.chineseMode.mode })
            ]
        ),
        ConfigSectionSchema(
            group: "Local App Settings",
            name: "localapp.backend-endpoint",
            fields: [
                stringField("localapp.backend-endpoint", "mode", comment: #"Options: "local", "remote""#,
                            options: ["local", "remote"],
                            apply: { $0.backend.mode = ["local", "remote"].contains($1) ? $1 : "local" },
                            render: { $0.backend.mode }),
                stringField("localapp.backend-endpoint", "local_endpoint",
                            apply: { $0.backend.localEndpoint = $1 },
                            render: { $0.backend.localEndpoint }),
                stringField("localapp.backend-endpoint", "remote_endpoint",
                            apply: { $0.backend.remoteEndpoint = $1 },
                            render: { $0.backend.remoteEndpoint })
            ]
        ),
        ConfigSectionSchema(
            group: "Local App Settings",
            name: "localapp.remote-asr",
            fields: [
                stringField("localapp.remote-asr", "name", comment: "Unique profile name. Apply/Save of the selected row writes [localapp] default-remote-asr-name.",
                            apply: { $0.remoteASR.name = $1.isEmpty ? "default" : $1 },
                            render: { $0.remoteASR.name }),
                stringField("localapp.remote-asr", "endpoint",
                            comment: "Remote ASR server URL. Empty uses [localapp.backend-endpoint].remote_endpoint.",
                            apply: { $0.remoteASR.endpoint = $1 },
                            render: { $0.remoteASR.endpoint }),
                stringField("localapp.remote-asr", "protocol", comment: #"Options: "webui-ime", "openai""#,
                            options: ["webui-ime", "openai"],
                            apply: { $0.remoteASR.protocolName = ["webui-ime", "openai"].contains($1) ? $1 : "webui-ime" },
                            render: { $0.remoteASR.protocolName }),
                stringField("localapp.remote-asr", "model", comment: "Model id for the openai protocol (ignored by webui-ime).",
                            apply: { $0.remoteASR.model = $1 },
                            render: { $0.remoteASR.model }),
                stringField("localapp.remote-asr", "api_key", kind: .secret,
                            comment: "Bearer token for the openai protocol. webui-ime uses [webui.auth].",
                            apply: { $0.remoteASR.apiKey = $1 },
                            render: { $0.remoteASR.apiKey })
            ]
        ),
        ConfigSectionSchema(
            group: "Local App Settings",
            name: "localapp.microphone",
            fields: [
                stringField("localapp.microphone", "selected_device_name", comment: "Microphone Device Name. Leave empty to use the system default microphone.",
                            apply: { $0.microphone.selectedDeviceName = $1 },
                            render: { $0.microphone.selectedDeviceName }),
                stringField("localapp.microphone", "mode", comment: #"Microphone Mode. Options: "on_demand", "always""#,
                            options: ["on_demand", "always"],
                            apply: { $0.microphone.mode = normalizeMicrophoneMode($1) },
                            render: { $0.microphone.mode }),
                intField("localapp.microphone", "always_on_timeout_minutes",
                         comment: "Release an Always On microphone after this many idle minutes. Use 0 to disable the timeout.",
                         apply: { $0.microphone.alwaysOnTimeoutMinutes = clamp(parseInt($1, defaultValue: 10), minimum: 0, maximum: 480) },
                         render: { String($0.microphone.alwaysOnTimeoutMinutes) }),
                numberField("localapp.microphone", "pre_roll_seconds",
                            apply: { $0.microphone.preRollSeconds = clamp(parseDouble($1, defaultValue: 2.0), minimum: 0.0, maximum: 5.0) },
                            render: { format($0.microphone.preRollSeconds) })
            ]
        ),
        ConfigSectionSchema(
            group: "Local App Settings",
            name: "localapp.recording",
            fields: [
                stringField("localapp.recording", "hotkey_press_count",
                            comment: #"Hotkey presses to start/stop. Options: "single", "double". Default single."#,
                            options: ["single", "double"],
                            apply: { $0.recording.hotkeyPressCount = normalizeHotkeyPressCount($1) },
                            render: { $0.recording.hotkeyPressCount }),
                stringField("localapp.recording", "hotkey_trigger",
                            comment: #"Physical hotkey. Options: "right_ctrl", "right_option", "right_command", "auto". Default auto. Legacy "right_alt" normalizes to right_option."#,
                            options: ["right_ctrl", "right_option", "right_command", "auto"],
                            apply: { $0.recording.hotkeyTrigger = normalizeHotkeyTrigger($1) },
                            render: { $0.recording.hotkeyTrigger }),
                boolField("localapp.recording", "play_cues",
                          comment: "Play quiet system sounds when recording capture starts and after it stops.",
                          apply: { $0.recording.playCues = parseBool($1, defaultValue: true) },
                          render: { $0.recording.playCues ? "true" : "false" })
            ]
        ),
        ConfigSectionSchema(
            group: "Local App Settings",
            name: "localapp.obsidian",
            fields: [
                stringField("localapp.obsidian", "vault_path",
                            comment: "Absolute path to the Obsidian vault folder where notes are written (e.g. .../Documents/airtype).",
                            apply: { $0.obsidian.vaultPath = $1 },
                            render: { $0.obsidian.vaultPath }),
                stringField("localapp.obsidian", "default_folder",
                            comment: "Optional subfolder under the vault. Leave empty to write at the vault root.",
                            apply: { $0.obsidian.defaultFolder = $1 },
                            render: { $0.obsidian.defaultFolder })
            ]
        ),
        ConfigSectionSchema(
            group: "Local App Settings",
            name: "localapp.local-whisper",
            fields: [
                boolField("localapp.local-whisper", "enabled",
                          apply: { $0.localWhisper.enabled = parseBool($1, defaultValue: false) },
                          render: { $0.localWhisper.enabled ? "true" : "false" }),
                stringField("localapp.local-whisper", "server_bin",
                            apply: { $0.localWhisper.serverBin = $1 },
                            render: { $0.localWhisper.serverBin }),
                stringField("localapp.local-whisper", "host",
                            apply: { $0.localWhisper.host = $1.isEmpty ? "127.0.0.1" : $1 },
                            render: { $0.localWhisper.host }),
                intField("localapp.local-whisper", "port",
                         apply: { $0.localWhisper.port = clamp(parseInt($1, defaultValue: 8080), minimum: 1, maximum: 65535) },
                         render: { String($0.localWhisper.port) }),
                intField("localapp.local-whisper", "max_threads",
                         apply: { $0.localWhisper.maxThreads = clamp(parseInt($1, defaultValue: 4), minimum: 1, maximum: 256) },
                         render: { String($0.localWhisper.maxThreads) }),
                intField("localapp.local-whisper", "max_gpu",
                         apply: { $0.localWhisper.maxGpu = clamp(parseInt($1, defaultValue: 1), minimum: 0, maximum: 16) },
                         render: { String($0.localWhisper.maxGpu) }),
                stringField("localapp.local-whisper", "server_args",
                            apply: { $0.localWhisper.serverArgs = $1 },
                            render: { $0.localWhisper.serverArgs }),
                stringField("localapp.local-whisper", "model_dir",
                            apply: { $0.localWhisper.modelDir = $1 },
                            render: { $0.localWhisper.modelDir }),
                stringField("localapp.local-whisper", "model_filename",
                            apply: { $0.localWhisper.modelFilename = $1 },
                            render: { $0.localWhisper.modelFilename }),
                stringField("localapp.local-whisper", "language",
                            options: ["zh-tw", "zh-cn", "en", "auto"],
                            apply: { $0.localWhisper.language = $1.isEmpty ? "zh-tw" : $1 },
                            render: { $0.localWhisper.language }),
                intField("localapp.local-whisper", "beam",
                         apply: { $0.localWhisper.beam = clamp(parseInt($1, defaultValue: 5), minimum: 1, maximum: 16) },
                         render: { String($0.localWhisper.beam) }),
                numberField("localapp.local-whisper", "temperature",
                            apply: { $0.localWhisper.temperature = clamp(parseDouble($1, defaultValue: 0), minimum: 0, maximum: 2) },
                            render: { format($0.localWhisper.temperature) }),
                stringField("localapp.local-whisper", "vocabulary_prompt",
                            apply: { $0.localWhisper.vocabularyPrompt = $1 },
                            render: { $0.localWhisper.vocabularyPrompt }),
                boolField("localapp.local-whisper", "no_timestamps",
                          apply: { $0.localWhisper.noTimestamps = parseBool($1, defaultValue: true) },
                          render: { $0.localWhisper.noTimestamps ? "true" : "false" }),
                boolField("localapp.local-whisper", "no_language_symbol",
                          apply: { $0.localWhisper.noLanguageSymbol = parseBool($1, defaultValue: true) },
                          render: { $0.localWhisper.noLanguageSymbol ? "true" : "false" })
            ]
        ),
        ConfigSectionSchema(
            group: "Local App Settings",
            name: "localapp",
            fields: [
                stringField("localapp", "default-remote-asr-name", comment: "Active [[localapp.remote-asr]] profile.",
                            apply: { $0.selectedRemoteASRName = $1 },
                            render: { $0.selectedRemoteASRName.isEmpty ? $0.remoteASR.name : $0.selectedRemoteASRName })
            ]
        ),
        ConfigSectionSchema(
            group: "Web UI Settings",
            name: "webui.auth",
            fields: [
                boolField("webui.auth", "enabled", comment: "Require HTTP Basic authentication for the Web UI and API.",
                          apply: { $0.webui.auth.enabled = parseBool($1, defaultValue: false) },
                          render: { $0.webui.auth.enabled ? "true" : "false" }),
                stringField("webui.auth", "username",
                            apply: { $0.webui.auth.username = $1.isEmpty ? "airtype" : $1 },
                            render: { $0.webui.auth.username }),
                stringField("webui.auth", "password", kind: .secret,
                            apply: { $0.webui.auth.password = $1 },
                            render: { $0.webui.auth.password })
            ]
        ),
        ConfigSectionSchema(
            group: "Web UI Settings",
            name: "webui.whisper-server",
            fields: [
                stringField("webui.whisper-server", "name",
                            apply: { $0.webui.whisper.name = $1.isEmpty ? "default" : $1 },
                            render: { $0.webui.whisper.name }),
                stringField("webui.whisper-server", "remote_endpoint",
                            apply: { $0.webui.whisper.remoteEndpoint = $1 },
                            render: { $0.webui.whisper.remoteEndpoint }),
                numberField("webui.whisper-server", "temperature",
                            apply: { $0.webui.whisper.temperature = clamp(parseDouble($1, defaultValue: 0), minimum: 0, maximum: 2) },
                            render: { format($0.webui.whisper.temperature) }),
                intField("webui.whisper-server", "beam",
                         apply: { $0.webui.whisper.beam = clamp(parseInt($1, defaultValue: 5), minimum: 1, maximum: 16) },
                         render: { String($0.webui.whisper.beam) }),
                stringField("webui.whisper-server", "language",
                            apply: { $0.webui.whisper.language = $1.isEmpty ? "zh-tw" : $1 },
                            render: { $0.webui.whisper.language })
            ]
        ),
        ConfigSectionSchema(
            group: "Web UI Settings",
            name: "webui.llm-server",
            fields: [
                stringField("webui.llm-server", "name", comment: "Unique name for this LLM server.",
                            apply: { $0.webui.llm.name = $1.isEmpty ? "default" : $1 },
                            render: { $0.webui.llm.name }),
                stringField("webui.llm-server", "provider",
                            apply: { $0.webui.llm.provider = $1.isEmpty ? "llama.cpp" : $1 },
                            render: { $0.webui.llm.provider }),
                stringField("webui.llm-server", "endpoint",
                            apply: { $0.webui.llm.endpoint = $1.isEmpty ? "http://127.0.0.1:8080" : $1 },
                            render: { $0.webui.llm.endpoint }),
                stringField("webui.llm-server", "api_key", kind: .secret,
                            apply: { $0.webui.llm.apiKey = $1 },
                            render: { $0.webui.llm.apiKey }),
                stringField("webui.llm-server", "selected-model",
                            apply: {
                                $0.webui.llm.selectedModel = $1
                            },
                            render: { $0.webui.llm.selectedModel }),
                intField("webui.llm-server", "contextLength",
                         apply: { $0.webui.llm.contextLength = max(1, parseInt($1, defaultValue: 8192)) },
                         render: { String($0.webui.llm.contextLength) }),
                numberField("webui.llm-server", "temperature",
                            apply: { $0.webui.llm.temperature = clamp(parseDouble($1, defaultValue: 0.4), minimum: 0, maximum: 2) },
                            render: { format($0.webui.llm.temperature) }),
                boolField("webui.llm-server", "thinking",
                          apply: { $0.webui.llm.thinking = parseBool($1, defaultValue: false) },
                          render: { $0.webui.llm.thinking ? "true" : "false" }),
                stringField("webui.llm-server", "system",
                            apply: { $0.webui.llm.system = $1 },
                            render: { $0.webui.llm.system })
            ]
        ),
        ConfigSectionSchema(
            group: "Web UI Settings",
            name: "webui",
            fields: [
                stringField("webui", "default-llm-server-name",
                            apply: { $0.webui.selectedServerName = $1.isEmpty ? "default" : $1 },
                            render: { $0.webui.selectedServerName }),
                stringField("webui", "default-whisper-server-name",
                            apply: { $0.webui.selectedWhisperServerName = $1 },
                            render: { $0.webui.selectedWhisperServerName.isEmpty ? $0.webui.whisper.name : $0.webui.selectedWhisperServerName })
            ]
        )
    ]

    private static func stringField(
        _ section: String,
        _ key: String,
        kind: ConfigFieldKind = .string,
        comment: String? = nil,
        options: [String] = [],
        apply: @escaping (inout AirTypeConfig, String) -> Void,
        render: @escaping (AirTypeConfig) -> String
    ) -> ConfigFieldSchema {
        ConfigFieldSchema(
            section: section,
            key: key,
            comment: comment,
            apply: apply,
            render: render,
            kind: kind,
            options: options
        )
    }

    private static func arrayField(
        _ section: String,
        _ key: String,
        comment: String? = nil,
        apply: @escaping (inout AirTypeConfig, [String]) -> Void,
        render: @escaping (AirTypeConfig) -> [String]
    ) -> ConfigFieldSchema {
        ConfigFieldSchema(
            section: section,
            key: key,
            comment: comment,
            apply: { config, value in
                let items = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                apply(&config, items)
            },
            render: { render($0).joined(separator: ", ") },
            kind: .array
        )
    }

    private static func numberField(
        _ section: String,
        _ key: String,
        comment: String? = nil,
        apply: @escaping (inout AirTypeConfig, String) -> Void,
        render: @escaping (AirTypeConfig) -> String
    ) -> ConfigFieldSchema {
        ConfigFieldSchema(section: section, key: key, comment: comment, apply: apply, render: render, kind: .number)
    }

    private static func intField(
        _ section: String,
        _ key: String,
        comment: String? = nil,
        apply: @escaping (inout AirTypeConfig, String) -> Void,
        render: @escaping (AirTypeConfig) -> String
    ) -> ConfigFieldSchema {
        ConfigFieldSchema(section: section, key: key, comment: comment, apply: apply, render: render, kind: .int)
    }

    private static func boolField(
        _ section: String,
        _ key: String,
        comment: String? = nil,
        apply: @escaping (inout AirTypeConfig, String) -> Void,
        render: @escaping (AirTypeConfig) -> String
    ) -> ConfigFieldSchema {
        ConfigFieldSchema(section: section, key: key, comment: comment, apply: apply, render: render, kind: .bool)
    }

    private static func normalizeLanguage(_ value: String) -> String {
        let lowered = value.lowercased()
        if ["traditional_chinese", "traditional", "tw", "zh_tw"].contains(lowered) {
            return "zh-tw"
        }
        if ["simple_chinese", "simplified_chinese", "simplified", "cn", "zh_cn"].contains(lowered) {
            return "zh-cn"
        }
        // localapp: engines are multilingual, so English and auto-detect are allowed too.
        // Auto is split by output script; legacy "auto" becomes Traditional auto.
        if ["auto", "auto-tw", "auto_tw", "auto-zh-tw", "auto-traditional"].contains(lowered) {
            return "auto-tw"
        }
        if ["auto-cn", "auto_cn", "auto-zh-cn", "auto-simplified"].contains(lowered) {
            return "auto-cn"
        }
        return ["zh-tw", "zh-cn", "en"].contains(lowered) ? lowered : "zh-tw"
    }

    private static func normalizeMicrophoneMode(_ value: String) -> String {
        let lowered = value.lowercased()
        if ["always", "always_warm", "warm"].contains(lowered) {
            return "always"
        }
        return "on_demand"
    }

    private static func normalizeHotkeyPressCount(_ value: String) -> String {
        let lowered = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ["double", "2", "two", "x2"].contains(lowered) {
            return "double"
        }
        return "single"
    }

    private static func normalizeHotkeyTrigger(_ value: String) -> String {
        let lowered = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch lowered {
        case "right_ctrl", "right-ctrl", "rightcontrol", "right_control", "ctrl":
            return "right_ctrl"
        case "right_option", "right-option", "rightoption", "option",
             "right_alt", "right-alt", "rightalt", "alt":
            // Alt and Option are the same key on macOS.
            return "right_option"
        case "right_command", "right-command", "rightcommand", "right_cmd", "right-cmd",
             "command", "cmd", "win", "windows":
            return "right_command"
        default:
            // "auto", legacy "both", and unknowns → all right-side triggers.
            return "auto"
        }
    }

    private static func parseBool(_ value: String, defaultValue: Bool) -> Bool {
        let lowered = value.lowercased()
        if ["1", "true", "yes", "on", "locked"].contains(lowered) {
            return true
        }
        if ["0", "false", "no", "off", "unlocked"].contains(lowered) {
            return false
        }
        return defaultValue
    }

    private static func parseDouble(_ value: String, defaultValue: Double) -> Double {
        Double(value) ?? defaultValue
    }

    private static func parseInt(_ value: String, defaultValue: Int) -> Int {
        Int(value) ?? Int(Double(value) ?? Double(defaultValue))
    }

    private static func clamp(_ value: Double, minimum: Double, maximum: Double) -> Double {
        min(maximum, max(minimum, value))
    }

    private static func clamp(_ value: Int, minimum: Int, maximum: Int) -> Int {
        min(maximum, max(minimum, value))
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.4f", value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    private static func findProjectRoot() -> URL? {
        let starts = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            Bundle.main.bundleURL.deletingLastPathComponent(),
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        ]

        for start in starts {
            if let root = findProjectRoot(startingAt: start) {
                return root
            }
        }
        return nil
    }

    private static func findProjectRoot(startingAt start: URL) -> URL? {
        var current = start
        while true {
            let backendPath = current.appendingPathComponent("source/webui/app/main.py").path
            if FileManager.default.fileExists(atPath: backendPath) {
                return current
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
    }

    private static var configPath: URL {
        AirTypeHome.configJSON
    }

    /// Ensure `~/.airtype/config.json` exists (create defaults if missing).
    private static func ensureConfigJSONExists() throws {
        let json = AirTypeHome.configJSON
        let fm = FileManager.default
        if fm.fileExists(atPath: json.path) { return }
        try fm.createDirectory(at: json.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try ConfigJSON.encode(AirTypeConfig())
        try data.write(to: json, options: .atomic)
        Logger.shared.log("Created default config.json at \(json.path)")
    }
}

enum ConfigStoreError: LocalizedError {
    case missingConfig(String)
    case unreadableConfig(String)

    var errorDescription: String? {
        switch self {
        case .missingConfig(let path):
            return "AirType config file was not found: \(path)\nRun ./scripts/setup.sh to create it, then start AirType again."
        case .unreadableConfig(let path):
            return "AirType config file could not be read: \(path)"
        }
    }
}
