import Foundation

struct AirTypeConfig {
    var chineseMode = ChineseMode()
    var backend = BackendConfig()
    var microphone = MicrophoneConfig()
    var floatingDialog = FloatingDialogConfig()
    var hotkey = HotkeyConfig()
    var webui = WebUIConfig()
}

struct ChineseMode {
    var mode = "zh-tw"
}

struct BackendConfig {
    var mode = "local"
    var localEndpoint = "http://localhost:8003"
    var remoteEndpoint = ""

    var selectedEndpoint: String {
        if mode == "remote", !remoteEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return remoteEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return localEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MicrophoneConfig {
    var selectedOrder = ""
    var mode = "on_demand"
    var preRollSeconds = 2.0
}

struct FloatingDialogConfig {
    var positionXRatio = 0.5
    var positionYRatio = 0.62
    var moveLock = true
}

struct HotkeyConfig {
    var trigger: HotkeyKey = .rightControl
}

struct WebUIConfig {
    var whisper = WhisperServerConfig()
    var llm = LLMServerConfig()
}

struct WhisperServerConfig {
    var modelDir = ""
    var modelFilename = ""
    var serverBin = ""
    var endpoint = ""
    var language = "zh-tw"
    var beam = 5
    var temperature = 0.0
}

struct LLMServerConfig {
    var provider = "llama.cpp"
    var endpoint = "http://127.0.0.1:8080"
    var model = ""
    var contextLength = 8192
    var temperature = 0.4
    var system = "Summarize and answer questions using the transcript as the source of truth."
}

final class ConfigStore: ObservableObject {
    @Published private(set) var config = AirTypeConfig()

    let projectRoot: URL?

    private let path: URL

    init() {
        let foundProjectRoot = Self.findProjectRoot()
        projectRoot = foundProjectRoot

        if let override = ProcessInfo.processInfo.environment["AIRTYPE_CONFIG_PATH"], !override.isEmpty {
            path = URL(fileURLWithPath: override)
        } else if let foundProjectRoot {
            path = foundProjectRoot.appendingPathComponent("config.toml")
        } else {
            path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".airtype/config.toml")
        }
    }

    func load() {
        ensureConfigExists()
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            Logger.shared.log("Could not read config: \(path.path)")
            return
        }
        config = Self.parse(text)
    }

    func updateChineseMode(_ mode: String) {
        config.chineseMode.mode = Self.normalizeLanguage(mode)
        save()
    }

    func updateMicrophone(_ order: String) {
        config.microphone.selectedOrder = order
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

    func updateHotkeyTrigger(_ trigger: HotkeyKey) {
        config.hotkey.trigger = trigger
        save()
    }

    func updateFloatingPosition(xRatio: Double, yRatio: Double) {
        config.floatingDialog.positionXRatio = Self.clamp(xRatio, minimum: 0.0, maximum: 1.0)
        config.floatingDialog.positionYRatio = Self.clamp(yRatio, minimum: 0.0, maximum: 1.0)
        save()
    }

    private func ensureConfigExists() {
        if FileManager.default.fileExists(atPath: path.path) {
            return
        }
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Self.tomlText(config).write(to: path, atomically: true, encoding: .utf8)
    }

    private static func parse(_ text: String) -> AirTypeConfig {
        let table = parseTomlTable(text)
        var parsed = AirTypeConfig()

        for section in schema {
            for field in section.fields {
                if let value = table[normalizedSection(field.section)]?[field.key] {
                    field.apply(&parsed, value)
                }
            }
        }

        return parsed
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

            lines.append("[\(section.name)]")
            for field in section.fields {
                if let comment = field.comment {
                    lines.append("# \(comment)")
                }
                lines.append("\(field.key) = \(field.render(config))")
            }
        }

        return lines.joined(separator: "\n") + "\n"
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
    }

    private static let schema: [ConfigSectionSchema] = [
        ConfigSectionSchema(
            group: "Local App Settings",
            name: "localapp.chinese-mode",
            fields: [
                stringField("localapp.chinese-mode", "mode", comment: #"Options: "zh-tw", "zh-cn""#,
                            apply: { $0.chineseMode.mode = normalizeLanguage($1) },
                            render: { $0.chineseMode.mode })
            ]
        ),
        ConfigSectionSchema(
            group: "Local App Settings",
            name: "localapp.backend-endpoint",
            fields: [
                stringField("localapp.backend-endpoint", "mode", comment: #"Options: "local", "remote""#,
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
            name: "localapp.microphone",
            fields: [
                stringField("localapp.microphone", "selected_order", comment: "Microphone Device. Leave empty to use the system default microphone.",
                            apply: { $0.microphone.selectedOrder = $1 },
                            render: { $0.microphone.selectedOrder }),
                stringField("localapp.microphone", "mode", comment: #"Microphone Mode. Options: "on_demand", "always""#,
                            apply: { $0.microphone.mode = normalizeMicrophoneMode($1) },
                            render: { $0.microphone.mode }),
                numberField("localapp.microphone", "pre_roll_seconds",
                            apply: { $0.microphone.preRollSeconds = clamp(parseDouble($1, defaultValue: 2.0), minimum: 0.0, maximum: 5.0) },
                            render: { format($0.microphone.preRollSeconds) })
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
            name: "localapp.hotkey",
            fields: [
                stringField("localapp.hotkey", "trigger", comment: #"Options: "right_ctrl", "right_option""#,
                            apply: { $0.hotkey.trigger = HotkeyKey(configValue: $1) },
                            render: { $0.hotkey.trigger.rawValue })
            ]
        ),
        ConfigSectionSchema(
            group: "Web UI Settings",
            name: "webui.whisper-server",
            fields: [
                stringField("webui.whisper-server", "model_dir",
                            apply: { $0.webui.whisper.modelDir = $1 },
                            render: { $0.webui.whisper.modelDir }),
                stringField("webui.whisper-server", "model_filename",
                            apply: { $0.webui.whisper.modelFilename = $1 },
                            render: { $0.webui.whisper.modelFilename }),
                stringField("webui.whisper-server", "server_bin",
                            apply: { $0.webui.whisper.serverBin = $1 },
                            render: { $0.webui.whisper.serverBin }),
                stringField("webui.whisper-server", "endpoint",
                            apply: { $0.webui.whisper.endpoint = $1 },
                            render: { $0.webui.whisper.endpoint }),
                stringField("webui.whisper-server", "language",
                            apply: { $0.webui.whisper.language = $1.isEmpty ? "zh-tw" : $1 },
                            render: { $0.webui.whisper.language }),
                intField("webui.whisper-server", "beam",
                         apply: { $0.webui.whisper.beam = clamp(parseInt($1, defaultValue: 5), minimum: 1, maximum: 16) },
                         render: { String($0.webui.whisper.beam) }),
                numberField("webui.whisper-server", "temperature",
                            apply: { $0.webui.whisper.temperature = clamp(parseDouble($1, defaultValue: 0), minimum: 0, maximum: 2) },
                            render: { format($0.webui.whisper.temperature) })
            ]
        ),
        ConfigSectionSchema(
            group: "Web UI Settings",
            name: "webui.llm-server",
            fields: [
                stringField("webui.llm-server", "provider",
                            apply: { $0.webui.llm.provider = $1.isEmpty ? "llama.cpp" : $1 },
                            render: { $0.webui.llm.provider }),
                stringField("webui.llm-server", "endpoint",
                            apply: { $0.webui.llm.endpoint = $1.isEmpty ? "http://127.0.0.1:8080" : $1 },
                            render: { $0.webui.llm.endpoint }),
                stringField("webui.llm-server", "model",
                            apply: { $0.webui.llm.model = $1 },
                            render: { $0.webui.llm.model }),
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
        )
    ]

    private static func stringField(
        _ section: String,
        _ key: String,
        comment: String? = nil,
        apply: @escaping (inout AirTypeConfig, String) -> Void,
        render: @escaping (AirTypeConfig) -> String
    ) -> ConfigFieldSchema {
        ConfigFieldSchema(
            section: section,
            key: key,
            comment: comment,
            apply: apply,
            render: { tomlString(render($0)) }
        )
    }

    private static func numberField(
        _ section: String,
        _ key: String,
        comment: String? = nil,
        apply: @escaping (inout AirTypeConfig, String) -> Void,
        render: @escaping (AirTypeConfig) -> String
    ) -> ConfigFieldSchema {
        ConfigFieldSchema(section: section, key: key, comment: comment, apply: apply, render: render)
    }

    private static func intField(
        _ section: String,
        _ key: String,
        comment: String? = nil,
        apply: @escaping (inout AirTypeConfig, String) -> Void,
        render: @escaping (AirTypeConfig) -> String
    ) -> ConfigFieldSchema {
        ConfigFieldSchema(section: section, key: key, comment: comment, apply: apply, render: render)
    }

    private static func boolField(
        _ section: String,
        _ key: String,
        comment: String? = nil,
        apply: @escaping (inout AirTypeConfig, String) -> Void,
        render: @escaping (AirTypeConfig) -> String
    ) -> ConfigFieldSchema {
        ConfigFieldSchema(section: section, key: key, comment: comment, apply: apply, render: render)
    }

    private static func parseTomlTable(_ text: String) -> [String: [String: String]] {
        var table: [String: [String: String]] = [:]
        var section = ""

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = stripComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                section = normalizedSection(String(trimmed.dropFirst().dropLast()))
                continue
            }

            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = unquote(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            table[section, default: [:]][key] = value
        }

        return table
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

    private static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
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
        return ["zh-tw", "zh-cn"].contains(lowered) ? lowered : "zh-tw"
    }

    private static func normalizeMicrophoneMode(_ value: String) -> String {
        let lowered = value.lowercased()
        if ["always", "always_warm", "warm"].contains(lowered) {
            return "always"
        }
        return "on_demand"
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
            let configPath = current.appendingPathComponent("config.toml").path
            let backendPath = current.appendingPathComponent("source/webui/app/main.py").path
            if FileManager.default.fileExists(atPath: configPath),
               FileManager.default.fileExists(atPath: backendPath) {
                return current
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
    }
}
