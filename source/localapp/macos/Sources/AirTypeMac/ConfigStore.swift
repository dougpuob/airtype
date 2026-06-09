import Foundation

struct AirTypeConfig {
    var chineseMode = ChineseMode()
    var backend = BackendConfig()
    var microphone = MicrophoneConfig()
    var floatingDialog = FloatingDialogConfig()
    var hotkey = HotkeyConfig()
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
        config = parse(text)
    }

    func updateChineseMode(_ mode: String) {
        config.chineseMode.mode = ["zh-tw", "zh-cn"].contains(mode) ? mode : "zh-tw"
        save()
    }

    func updateMicrophone(_ order: String) {
        config.microphone.selectedOrder = order
        save()
    }

    func updateMicrophoneMode(_ mode: String) {
        config.microphone.mode = ["on_demand", "always"].contains(mode) ? mode : "on_demand"
        save()
    }

    func updatePreRollSeconds(_ seconds: Double) {
        config.microphone.preRollSeconds = min(5.0, max(0.0, seconds))
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
        config.floatingDialog.positionXRatio = min(1.0, max(0.0, xRatio))
        config.floatingDialog.positionYRatio = min(1.0, max(0.0, yRatio))
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
        try? defaultConfigText().write(to: path, atomically: true, encoding: .utf8)
    }

    private func parse(_ text: String) -> AirTypeConfig {
        var parsed = AirTypeConfig()
        var section = ""

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                section = String(trimmed.dropFirst().dropLast())
                continue
            }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = unquote(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))

            switch (normalizedSection(section), key) {
            case ("localapp.chinese-mode", "mode"):
                parsed.chineseMode.mode = normalizeLanguage(value)
            case ("localapp.backend-endpoint", "mode"):
                parsed.backend.mode = value
            case ("localapp.backend-endpoint", "local_endpoint"):
                parsed.backend.localEndpoint = value
            case ("localapp.backend-endpoint", "remote_endpoint"):
                parsed.backend.remoteEndpoint = value
            case ("localapp.microphone", "selected_order"):
                parsed.microphone.selectedOrder = value
            case ("localapp.microphone", "mode"):
                parsed.microphone.mode = normalizeMicrophoneMode(value)
            case ("localapp.microphone", "warm_mode"):
                parsed.microphone.mode = normalizeMicrophoneMode(value)
            case ("localapp.microphone", "pre_roll_seconds"):
                parsed.microphone.preRollSeconds = Double(value) ?? 2.0
            case ("localapp.floating-dialog", "position_x_ratio"):
                parsed.floatingDialog.positionXRatio = Double(value) ?? 0.5
            case ("localapp.floating-dialog", "position_y_ratio"):
                parsed.floatingDialog.positionYRatio = Double(value) ?? 0.62
            case ("localapp.floating-dialog", "move_lock"):
                parsed.floatingDialog.moveLock = parseBool(value, defaultValue: true)
            case ("localapp.hotkey", "trigger"):
                parsed.hotkey.trigger = HotkeyKey(configValue: value)
            default:
                continue
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
            try tomlText().write(to: path, atomically: true, encoding: .utf8)
        } catch {
            Logger.shared.log("Could not write config: \(error)")
        }
    }

    private func tomlText() -> String {
        """
        # AirType user config
        # Local app settings live under [localapp.*].
        # Web UI runtime settings live under [webui.*].

        [localapp.chinese-mode]
        # Options: "zh-tw", "zh-cn"
        mode = "\(config.chineseMode.mode)"

        [localapp.backend-endpoint]
        # Options: "local", "remote"
        mode = "\(config.backend.mode)"
        local_endpoint = "\(config.backend.localEndpoint)"
        remote_endpoint = "\(config.backend.remoteEndpoint)"

        [localapp.microphone]
        # Microphone Device. Leave empty to use the system default microphone.
        selected_order = "\(config.microphone.selectedOrder)"
        # Microphone Mode. Options: "on_demand", "always"
        mode = "\(config.microphone.mode)"
        pre_roll_seconds = \(format(config.microphone.preRollSeconds))

        [localapp.floating-dialog]
        # Position is stored as the dialog center ratio across the whole desktop.
        position_x_ratio = \(format(config.floatingDialog.positionXRatio))
        position_y_ratio = \(format(config.floatingDialog.positionYRatio))
        move_lock = \(config.floatingDialog.moveLock ? "true" : "false")

        [localapp.hotkey]
        # Options: "right_ctrl", "right_option"
        trigger = "\(config.hotkey.trigger.rawValue)"

        """
    }

    private func defaultConfigText() -> String {
        tomlText()
    }

    private func unquote(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text.removeFirst()
            text.removeLast()
        }
        return text.replacingOccurrences(of: "\\\"", with: "\"")
    }

    private func normalizedSection(_ section: String) -> String {
        switch section {
        case "localapp.backend":
            return "localapp.backend-endpoint"
        case "localapp.backend_endpoint":
            return "localapp.backend-endpoint"
        default:
            return section
        }
    }

    private func normalizeLanguage(_ value: String) -> String {
        let lowered = value.lowercased()
        if ["traditional_chinese", "traditional", "tw", "zh_tw"].contains(lowered) {
            return "zh-tw"
        }
        if ["simple_chinese", "simplified_chinese", "simplified", "cn", "zh_cn"].contains(lowered) {
            return "zh-cn"
        }
        return ["zh-tw", "zh-cn"].contains(lowered) ? lowered : "zh-tw"
    }

    private func normalizeMicrophoneMode(_ value: String) -> String {
        let lowered = value.lowercased()
        if ["always", "always_warm", "warm"].contains(lowered) {
            return "always"
        }
        return "on_demand"
    }

    private func parseBool(_ value: String, defaultValue: Bool) -> Bool {
        let lowered = value.lowercased()
        if ["1", "true", "yes", "on", "locked"].contains(lowered) {
            return true
        }
        if ["0", "false", "no", "off", "unlocked"].contains(lowered) {
            return false
        }
        return defaultValue
    }

    private func format(_ value: Double) -> String {
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
