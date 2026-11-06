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
    var launchOnStart = false
    var serverBin = ""
    var serverArgs = ""
    var modelDir = ""
    var modelFilename = ""
    var language = "zh-tw"
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

/// Field metadata exposed to the Settings window (mirrors the TOML schema).
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

struct MicrophoneConfig {
    var selectedDeviceName = ""
    var mode = "on_demand"
    var alwaysOnTimeoutMinutes = 10
    var preRollSeconds = 2.0
}

struct FloatingDialogConfig {
    var positionXRatio = 0.5
    var positionYRatio = 0.62
    var moveLock = true
}

/// [localapp.recording]: hotkey gesture + optional start/end cues.
struct RecordingConfig {
    /// "single" (default) or "double" — how many exclusive Right Ctrl/Option presses start/stop.
    var hotkeyPressCount = "single"
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
        self.system = system
    }
}

final class ConfigStore: ObservableObject {
    @Published private(set) var config = AirTypeConfig()

    let projectRoot: URL?

    private let path: URL

    init() {
        let foundProjectRoot = Self.findProjectRoot()
        projectRoot = foundProjectRoot

        path = Self.configPath
    }

    func load() throws {
        Self.seedExperimentConfigIfNeeded(at: path)
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw ConfigStoreError.missingConfig(path.path)
        }
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            throw ConfigStoreError.unreadableConfig(path.path)
        }
        config = Self.parse(text)
        logLoadedConfig()
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
            "Config localapp: hotkey_triggers=right_ctrl,right_option; "
            + "chinese_mode=\(config.chineseMode.mode); "
            + "floating_dialog=(x=\(config.floatingDialog.positionXRatio), y=\(config.floatingDialog.positionYRatio), move_lock=\(config.floatingDialog.moveLock))"
        )
        Logger.shared.log(
            "Config localapp.recording: hotkey_press_count=\(config.recording.hotkeyPressCount), "
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
            "Config localapp.local-whisper: enabled=\(config.localWhisper.enabled), launch_on_start=\(config.localWhisper.launchOnStart), "
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

    /// Settings window: replace the whole config and write it back to config.toml.
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

    /// Plain (unquoted) value of a field; arrays are returned comma-separated.
    static func displayValue(section: String, key: String, in config: AirTypeConfig) -> String {
        guard let field = schema.first(where: { $0.name == section })?.fields.first(where: { $0.key == key }) else { return "" }
        let rendered = field.render(config)
        if field.kind == .array {
            return parseTomlStringArray(rendered).joined(separator: ", ")
        }
        return parseTomlValue(rendered)
    }

    /// Applies a plain value (arrays comma-separated) through the same validation as the TOML parser.
    static func apply(section: String, key: String, value: String, to config: inout AirTypeConfig) {
        guard let field = schema.first(where: { $0.name == section })?.fields.first(where: { $0.key == key }) else { return }
        if field.kind == .array {
            let items = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            field.apply(&config, tomlStringArray(items))
        } else {
            field.apply(&config, value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
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

    func updateMoveLock(_ locked: Bool) {
        config.floatingDialog.moveLock = locked
        save()
    }

    func updateFloatingPosition(xRatio: Double, yRatio: Double) {
        config.floatingDialog.positionXRatio = Self.clamp(xRatio, minimum: 0.0, maximum: 1.0)
        config.floatingDialog.positionYRatio = Self.clamp(yRatio, minimum: 0.0, maximum: 1.0)
        save()
    }

    func updateLLMServer(_ serverName: String) {
        config.webui.selectedServerName = serverName
        // Also update the active llm config to match the selected server
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return }
        let entries = Self.parseAllLLMServers(from: text)
        if let entry = Self.llmServerEntry(for: serverName, in: entries) {
            config.webui.llm = Self.config(from: entry)
            config.webui.llmServers = entries.map(Self.config(from:))
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
        if let text = try? String(contentsOf: path, encoding: .utf8) {
            let entries = Self.parseAllLLMServers(from: text)
            if let entry = Self.llmServerEntry(for: serverName, in: entries) {
                config.webui.llm = Self.config(from: entry)
                config.webui.llm.selectedModel = modelName
                config.webui.llmServers = entries.map(Self.config(from:))
                syncActiveLLMServer()
            }
            let patched = Self.patchLLMSelection(in: text, serverName: serverName, modelName: modelName)
            do {
                try patched.write(to: path, atomically: true, encoding: .utf8)
            } catch {
                Logger.shared.log("Could not write LLM selection: \(error)")
            }
        } else {
            config.webui.llm.selectedModel = modelName
            save()
        }
    }

    func updateLLMServerModels(_ modelsByServer: [String: [String]]) {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return }
        let patched = Self.patchLLMServerModels(in: text, modelsByServer: modelsByServer)
        do {
            try patched.write(to: path, atomically: true, encoding: .utf8)
            try load()
        } catch {
            Logger.shared.log("Could not write LLM server models: \(error)")
        }
    }

    func availableLLMServers() -> [LLMServerEntry] {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            return []
        }
        return Self.parseAllLLMServers(from: text)
    }

    private static func parseAllLLMServers(from text: String) -> [LLMServerEntry] {
        var entries: [LLMServerEntry] = []
        var currentTable: [String: String] = [:]
        var inLLMSection = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = stripComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[["), trimmed.hasSuffix("]]") {
                if inLLMSection && !currentTable.isEmpty {
                    entries.append(Self.makeEntry(from: currentTable))
                }
                let sectionName = String(trimmed.dropFirst(2).dropLast(2))
                inLLMSection = sectionName.hasPrefix("webui.llm-server")
                currentTable = [:]
            } else if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                if inLLMSection && !currentTable.isEmpty {
                    entries.append(Self.makeEntry(from: currentTable))
                }
                inLLMSection = false
                currentTable = [:]
            } else if inLLMSection, let eqIndex = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = parseTomlValue(String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines))
                currentTable[key] = value
            }
        }
        if inLLMSection && !currentTable.isEmpty {
            entries.append(Self.makeEntry(from: currentTable))
        }
        return entries
    }

    private static func makeEntry(from table: [String: String]) -> LLMServerEntry {
        let name = table["name"] ?? "default"
        let provider = table["provider"] ?? "llama.cpp"
        let endpoint = table["endpoint"] ?? "http://127.0.0.1:8080"
        let apiKey = table["api_key"] ?? table["api-key"] ?? ""
        let models = parseTomlStringArray(table["models"] ?? "")
        let selectedModel = table["selected-model"] ?? table["default_model"] ?? table["model"] ?? ""
        let contextLength = parseInt(table["contextLength"] ?? "8192", defaultValue: 8192)
        let temperature = parseDouble(table["temperature"] ?? "0.4", defaultValue: 0.4)
        let system = table["system"] ?? ""
        return LLMServerEntry(
            name: name, provider: provider, endpoint: endpoint, apiKey: apiKey,
            models: models, selectedModel: selectedModel, contextLength: contextLength,
            temperature: temperature, system: system
        )
    }

    private static func llmServerEntry(for name: String, in entries: [LLMServerEntry]) -> LLMServerEntry? {
        entries.first { $0.name == name }
    }

    private static func config(from entry: LLMServerEntry) -> LLMServerConfig {
        LLMServerConfig(
            name: entry.name,
            provider: entry.provider,
            endpoint: entry.endpoint,
            apiKey: entry.apiKey,
            models: entry.models,
            selectedModel: entry.selectedModel,
            contextLength: entry.contextLength,
            temperature: entry.temperature,
            system: entry.system
        )
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

    private static func parse(_ text: String) -> AirTypeConfig {
        let tables = parseTomlTables(text)
        var parsed = AirTypeConfig()

        for section in schema {
            for field in section.fields {
                let normalized = normalizedSection(field.section)
                if let table = tables[normalized], let value = table[field.key] {
                    field.apply(&parsed, value)
                }
            }
        }
        if parsed.microphone.selectedDeviceName.isEmpty,
           let value = tables["localapp.microphone"]?["selected_order"] {
            parsed.microphone.selectedDeviceName = value
        }

        let entries = parseAllLLMServers(from: text)
        if !entries.isEmpty {
            parsed.webui.llmServers = entries.map(config(from:))
            let selectedName = parsed.webui.selectedServerName.isEmpty ? entries[0].name : parsed.webui.selectedServerName
            parsed.webui.selectedServerName = selectedName
            if let selected = entries.first(where: { $0.name == selectedName }) ?? entries.first {
                parsed.webui.llm = config(from: selected)
                parsed.webui.selectedModelName = selected.selectedModel
            }
        }

        // Remote ASR profiles: [[localapp.remote-asr]] (legacy single [localapp.remote-asr] → one profile "default").
        let asrProfiles = uniquelyNamed(
            profileTables(in: text, section: "localapp.remote-asr").map { table -> RemoteASRConfig in
                var scratch = AirTypeConfig()
                apply(table: table, section: "localapp.remote-asr", to: &scratch)
                return scratch.remoteASR
            },
            name: \.name
        )
        parsed.remoteASRProfiles = asrProfiles.isEmpty ? [parsed.remoteASR] : asrProfiles
        let asrActive = parsed.remoteASRProfiles.first(where: { $0.name == parsed.selectedRemoteASRName }) ?? parsed.remoteASRProfiles[0]
        parsed.remoteASR = asrActive
        parsed.selectedRemoteASRName = asrActive.name

        // Whisper profiles: [[webui.whisper-server]] (legacy single [webui.whisper-server] → one profile "default").
        let whisperTables = profileTables(in: text, section: "webui.whisper-server")
        let whisperProfiles = uniquelyNamed(
            whisperTables.map { table -> WhisperServerConfig in
                var scratch = AirTypeConfig()
                apply(table: table, section: "webui.whisper-server", to: &scratch)
                return scratch.webui.whisper
            },
            name: \.name
        )
        parsed.webui.whisperServers = whisperProfiles.isEmpty ? [parsed.webui.whisper] : whisperProfiles
        let whisperActive = parsed.webui.whisperServers.first(where: { $0.name == parsed.webui.selectedWhisperServerName })
            ?? parsed.webui.whisperServers[0]
        parsed.webui.whisper = whisperActive
        parsed.webui.selectedWhisperServerName = whisperActive.name

        // Migration: older configs kept self-host keys (server_bin, model_dir, …) on the whisper-server table.
        if tables["localapp.local-whisper"] == nil {
            let legacy = whisperTables.first(where: { ($0["name"] ?? "default") == whisperActive.name }) ?? whisperTables.first
            if let legacy {
                apply(table: legacy, section: "localapp.local-whisper", to: &parsed)
                let remote = (legacy["remote_endpoint"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let model = (legacy["model_filename"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                parsed.localWhisper.enabled = remote.isEmpty && !model.isEmpty
            }
        }

        return parsed
    }

    /// Every table (`[section]` or `[[section]]`) whose normalized name is `section`, in file order.
    private static func profileTables(in text: String, section: String) -> [[String: String]] {
        var tables: [[String: String]] = []
        var current: [String: String]?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = stripComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                if let current { tables.append(current) }
                let isArray = trimmed.hasPrefix("[[") && trimmed.hasSuffix("]]")
                let name = isArray ? String(trimmed.dropFirst(2).dropLast(2)) : String(trimmed.dropFirst().dropLast())
                current = normalizedSection(name.trimmingCharacters(in: .whitespaces)) == section ? [:] : nil
            } else if current != nil, let eqIndex = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                current?[key] = parseTomlValue(String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        if let current { tables.append(current) }
        return tables
    }

    private static func apply(table: [String: String], section: String, to config: inout AirTypeConfig) {
        guard let schemaSection = schema.first(where: { $0.name == section }) else { return }
        for field in schemaSection.fields {
            if let value = table[field.key] { field.apply(&config, value) }
        }
    }

    /// Duplicate profile names get "-2", "-3", … so selection by name stays unambiguous.
    private static func uniquelyNamed<T>(_ items: [T], name: WritableKeyPath<T, String>) -> [T] {
        var seen = Set<String>()
        return items.map { item in
            var item = item
            var candidate = item[keyPath: name]
            var suffix = 2
            while seen.contains(candidate) { candidate = "\(item[keyPath: name])-\(suffix)"; suffix += 1 }
            item[keyPath: name] = candidate
            seen.insert(candidate)
            return item
        }
    }

    /// Per-profile copies of `config` for the array sections, with the active profile synced into its slot.
    private static func profileVariants(for sectionName: String, in config: AirTypeConfig) -> [AirTypeConfig]? {
        switch sectionName {
        case "webui.llm-server":
            let servers = config.webui.llmServers.isEmpty ? [config.webui.llm] : config.webui.llmServers
            return servers.map { var copy = config; copy.webui.llm = $0; return copy }
        case "localapp.remote-asr":
            var profiles = config.remoteASRProfiles
            let activeName = config.selectedRemoteASRName.isEmpty ? config.remoteASR.name : config.selectedRemoteASRName
            if let index = profiles.firstIndex(where: { $0.name == activeName }) {
                profiles[index] = config.remoteASR
            } else {
                profiles.append(config.remoteASR)
            }
            return profiles.map { var copy = config; copy.remoteASR = $0; return copy }
        case "webui.whisper-server":
            var profiles = config.webui.whisperServers
            let activeName = config.webui.selectedWhisperServerName.isEmpty ? config.webui.whisper.name : config.webui.selectedWhisperServerName
            if let index = profiles.firstIndex(where: { $0.name == activeName }) {
                profiles[index] = config.webui.whisper
            } else {
                profiles.append(config.webui.whisper)
            }
            return profiles.map { var copy = config; copy.webui.whisper = $0; return copy }
        default:
            return nil
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try Self.tomlText(config).write(to: path, atomically: true, encoding: .utf8)
        } catch {
            Logger.shared.log("Could not write config: \(error)")
        }
    }

    private static func tomlText(_ config: AirTypeConfig) -> String {
        var lines: [String] = [
            "# AirType user config",
            "#:schema ./config.schema.json",
            "# Local app settings live under [localapp.*].",
            "# Web UI runtime settings live under [webui.*].",
            ""
        ]

        var previousGroup = ""
        for section in schema {
            if section.group != previousGroup {
                if !previousGroup.isEmpty {
                    lines.append("")
                }
                lines.append("#===============================================================================")
                lines.append("# \(section.group)")
                lines.append("#===============================================================================")
                lines.append("")
                previousGroup = section.group
            } else {
                lines.append("")
            }

            if let variants = profileVariants(for: section.name, in: config) {
                for (index, serverConfig) in variants.enumerated() {
                    if index > 0 {
                        lines.append("")
                    }
                    lines.append("[[\(section.name)]]")
                    for field in section.fields {
                        if let comment = field.comment {
                            lines.append("# \(comment)")
                        }
                        lines.append("\(field.key) = \(field.render(serverConfig))")
                    }
                }
            } else {
                let header = "[\(section.name)]"
                lines.append(header)
                for field in section.fields {
                    if let comment = field.comment {
                        lines.append("# \(comment)")
                    }
                    lines.append("\(field.key) = \(field.render(config))")
                }
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func patchLLMSelection(in text: String, serverName: String, modelName: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let modelPatchedLines = patchLLMServerDefaultModel(in: lines, serverName: serverName, modelName: modelName)
        let webuiPatchedLines = patchWebUISelection(in: modelPatchedLines, serverName: serverName)
        return webuiPatchedLines.joined(separator: "\n")
    }

    private static func patchLLMServerDefaultModel(in lines: [String], serverName: String, modelName: String) -> [String] {
        var output: [String] = []
        var block: [String] = []
        var inLLMServer = false

        func flushBlock() {
            guard inLLMServer else { return }
            let table = tableValues(from: block)
            if table["name"] == serverName {
                let patched = replacingOrAppending(key: "selected-model", value: tomlString(modelName), in: block)
                output.append(contentsOf: removing(keys: ["model", "default_model"], from: patched))
            } else {
                output.append(contentsOf: block)
            }
            block.removeAll()
            inLLMServer = false
        }

        for line in lines {
            let trimmed = stripComment(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[[") || trimmed.hasPrefix("[") {
                flushBlock()
                if trimmed == "[[webui.llm-server]]" {
                    inLLMServer = true
                    block = [line]
                } else {
                    output.append(line)
                }
            } else if inLLMServer {
                block.append(line)
            } else {
                output.append(line)
            }
        }
        flushBlock()
        return output
    }

    private static func patchLLMServerModels(in text: String, modelsByServer: [String: [String]]) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        var block: [String] = []
        var inLLMServer = false

        func flushBlock() {
            guard inLLMServer else { return }
            let table = tableValues(from: block)
            guard let serverName = table["name"], let modelNames = modelsByServer[serverName] else {
                output.append(contentsOf: block)
                block.removeAll()
                inLLMServer = false
                return
            }
            var patched = replacingOrAppending(key: "models", value: tomlStringArray(modelNames), in: block)
            let selectedModel = table["selected-model"] ?? table["default_model"] ?? table["model"] ?? ""
            if selectedModel.isEmpty || !modelNames.contains(selectedModel) {
                patched = replacingOrAppending(key: "selected-model", value: tomlString(modelNames.first ?? ""), in: patched)
            }
            output.append(contentsOf: removing(keys: ["model", "default_model"], from: patched))
            block.removeAll()
            inLLMServer = false
        }

        for line in lines {
            let trimmed = stripComment(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[[") || trimmed.hasPrefix("[") {
                flushBlock()
                if trimmed == "[[webui.llm-server]]" {
                    inLLMServer = true
                    block = [line]
                } else {
                    output.append(line)
                }
            } else if inLLMServer {
                block.append(line)
            } else {
                output.append(line)
            }
        }
        flushBlock()
        return output.joined(separator: "\n")
    }

    private static func patchWebUISelection(in lines: [String], serverName: String) -> [String] {
        var output: [String] = []
        var block: [String] = []
        var inWebUI = false
        var foundWebUI = false
        var shouldKeepCurrentWebUI = false

        func flushBlock() {
            guard inWebUI else { return }
            if shouldKeepCurrentWebUI {
                let patched = replacingOrAppending(key: "default-llm-server-name", value: tomlString(serverName), in: block)
                output.append(contentsOf: patched)
            }
            block.removeAll()
            inWebUI = false
            shouldKeepCurrentWebUI = false
        }

        for line in lines {
            let trimmed = stripComment(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[[") || trimmed.hasPrefix("[") {
                flushBlock()
                if trimmed == "[webui]" {
                    shouldKeepCurrentWebUI = !foundWebUI
                    foundWebUI = true
                    inWebUI = true
                    block = [line]
                } else {
                    output.append(line)
                }
            } else if inWebUI {
                block.append(line)
            } else {
                output.append(line)
            }
        }
        flushBlock()

        if !foundWebUI {
            if output.last?.isEmpty == false {
            output.append("")
            }
            output.append("[webui]")
            output.append("default-llm-server-name = \(tomlString(serverName))")
        }
        return output
    }

    private static func replacingOrAppending(key: String, value: String, in lines: [String]) -> [String] {
        var patched = lines
        let replacement = "\(key) = \(value)"
        if let index = patched.firstIndex(where: { line in
            let trimmed = stripComment(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eqIndex = trimmed.firstIndex(of: "=") else { return false }
            return trimmed[..<eqIndex].trimmingCharacters(in: .whitespacesAndNewlines) == key
        }) {
            patched[index] = replacement
        } else {
            patched.append(replacement)
        }
        return patched
    }

    private static func removing(keys: Set<String>, from lines: [String]) -> [String] {
        lines.filter { line in
            let trimmed = stripComment(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eqIndex = trimmed.firstIndex(of: "=") else { return true }
            let key = trimmed[..<eqIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            return !keys.contains(String(key))
        }
    }

    private static func tableValues(from lines: [String]) -> [String: String] {
        var values: [String: String] = [:]
        for line in lines {
            let trimmed = stripComment(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parseTomlValue(String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines))
            values[key] = value
        }
        return values
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
                stringField("localapp.remote-asr", "name", comment: "Unique profile name. [localapp] default-remote-asr-name picks the active one.",
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
                boolField("localapp.recording", "play_cues",
                          comment: "Play quiet system sounds when recording capture starts and after it stops.",
                          apply: { $0.recording.playCues = parseBool($1, defaultValue: true) },
                          render: { $0.recording.playCues ? "true" : "false" })
            ]
        ),
        ConfigSectionSchema(
            group: "Local App Settings",
            name: "localapp.floating-dialog",
            fields: [
                numberField("localapp.floating-dialog", "position_x_ratio", comment: "Position is stored as the dialog center ratio across the whole desktop.",
                            apply: { $0.floatingDialog.positionXRatio = clamp(parseDouble($1, defaultValue: 0.5), minimum: 0.0, maximum: 1.0) },
                            render: { format($0.floatingDialog.positionXRatio) }),
                numberField("localapp.floating-dialog", "position_y_ratio",
                            apply: { $0.floatingDialog.positionYRatio = clamp(parseDouble($1, defaultValue: 0.62), minimum: 0.0, maximum: 1.0) },
                            render: { format($0.floatingDialog.positionYRatio) }),
                boolField("localapp.floating-dialog", "move_lock",
                          apply: { $0.floatingDialog.moveLock = parseBool($1, defaultValue: true) },
                          render: { $0.floatingDialog.moveLock ? "true" : "false" })
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
                boolField("localapp.local-whisper", "launch_on_start",
                          apply: { $0.localWhisper.launchOnStart = parseBool($1, defaultValue: false) },
                          render: { $0.localWhisper.launchOnStart ? "true" : "false" }),
                stringField("localapp.local-whisper", "server_bin",
                            apply: { $0.localWhisper.serverBin = $1 },
                            render: { $0.localWhisper.serverBin }),
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
                            apply: { $0.localWhisper.language = $1.isEmpty ? "zh-tw" : $1 },
                            render: { $0.localWhisper.language }),
                intField("localapp.local-whisper", "beam",
                         apply: { $0.localWhisper.beam = clamp(parseInt($1, defaultValue: 5), minimum: 1, maximum: 16) },
                         render: { String($0.localWhisper.beam) }),
                numberField("localapp.local-whisper", "temperature",
                            apply: { $0.localWhisper.temperature = clamp(parseDouble($1, defaultValue: 0), minimum: 0, maximum: 2) },
                            render: { format($0.localWhisper.temperature) })
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
                            render: { $0.webui.whisper.remoteEndpoint })
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
                arrayField("webui.llm-server", "models",
                           apply: { $0.webui.llm.models = $1 },
                           render: { $0.webui.llm.models }),
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
            render: { tomlString(render($0)) },
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
            apply: { config, value in apply(&config, parseTomlStringArray(value)) },
            render: { tomlStringArray(render($0)) },
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

    private static func parseTomlTables(_ text: String) -> [String: [String: String]] {
        // Collect all sections: [section] -> [key: value], [[section]] -> [[key: value]]
        var sections: [String: [[String: String]]] = [:]
        var currentSection = ""
        var currentTable: [String: String] = [:]

        func flushTable() {
            if !currentSection.isEmpty {
                sections[currentSection, default: []].append(currentTable)
                currentTable = [:]
            }
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = stripComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            if trimmed.hasPrefix("[["), trimmed.hasSuffix("]]") {
                flushTable()
                currentSection = normalizedSection(String(trimmed.dropFirst(2).dropLast(2)))
                currentTable = [:]
            } else if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                flushTable()
                currentSection = normalizedSection(String(trimmed.dropFirst().dropLast()))
                currentTable = [:]
            } else if let eqIndex = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = parseTomlValue(String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines))
                currentTable[key] = value
            }
        }
        flushTable()

        // Find the default LLM server name from [webui] section
        var defaultLLMName: String?
        if let webuiTables = sections["webui"] {
            if let webuiTable = webuiTables.last,
               let name = webuiTable["default-llm-server-name"] {
                defaultLLMName = name.isEmpty ? nil : name
            }
        }

        // Select default for each section
        var result: [String: [String: String]] = [:]
        for (section, tables) in sections {
            if section.hasPrefix("webui.llm-server"), let defaultName = defaultLLMName {
                // Select the LLM server matching default-llm-server-name
                if let matched = tables.first(where: { $0["name"] == defaultName }) {
                    result[section] = matched
                } else if let first = tables.first {
                    result[section] = first
                }
            } else {
                result[section] = tables.last ?? [:]
            }
        }

        return result
    }

    private static func stripComment(_ line: String) -> String {
        var result = ""
        var inString = false
        var escaped = false
        for char in line {
            if escaped {
                result.append(char)
                escaped = false
            } else if char == "\\" && inString {
                result.append(char)
                escaped = true
            } else if char == "\"" {
                result.append(char)
                inString.toggle()
            } else if char == "#" && !inString {
                break
            } else {
                result.append(char)
            }
        }
        return result
    }

    private static func unquote(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text.removeFirst()
            text.removeLast()
        }
        return text
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func parseTomlValue(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("[") ? text : unquote(text)
    }

    private static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func tomlStringArray(_ values: [String]) -> String {
        "[\(values.map(tomlString).joined(separator: ", "))]"
    }

    private static func parseTomlStringArray(_ value: String) -> [String] {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("["), text.hasSuffix("]") else {
            return []
        }
        text.removeFirst()
        text.removeLast()

        var values: [String] = []
        var current = ""
        var inString = false
        var escaped = false
        for char in text {
            if escaped {
                current.append(char)
                escaped = false
            } else if char == "\\" && inString {
                escaped = true
            } else if char == "\"" {
                if inString {
                    values.append(current)
                    current = ""
                }
                inString.toggle()
            } else if inString {
                current.append(char)
            }
        }
        return values
    }

    private static func normalizedSection(_ section: String) -> String {
        switch section {
        case "localapp.backend", "localapp.backend_endpoint":
            return "localapp.backend-endpoint"
        case "webui.whisper":
            return "webui.whisper-server"
        case "webui.llm":
            return "webui.llm-server"
        default:
            return section
        }
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

    // localapp keeps its own config so menu changes never touch ~/.airtype/config.toml.
    private static var configPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".airtype-experiment/config.toml")
    }

    private static var originalConfigPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".airtype/config.toml")
    }

    /// First run: copy ~/.airtype/config.toml (read-only) to ~/.airtype-experiment/config.toml.
    private static func seedExperimentConfigIfNeeded(at path: URL) {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: path.path),
              fileManager.fileExists(atPath: originalConfigPath.path) else { return }
        do {
            try fileManager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: originalConfigPath, to: path)
            Logger.shared.log("Seeded experiment config from \(originalConfigPath.path) to \(path.path)")
        } catch {
            Logger.shared.log("Could not seed experiment config: \(error)")
        }
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
