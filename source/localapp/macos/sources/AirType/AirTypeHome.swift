import Foundation

/// Single home for AirType data under `~/.airtype` (or `$AIRTYPE_HOME`).
enum AirTypeHome {
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["AIRTYPE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".airtype", isDirectory: true)
    }

    static var configJSON: URL { root.appendingPathComponent("config.json") }
    static var experimentRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".airtype-experiment", isDirectory: true)
    }

    static var localAppLog: URL { root.appendingPathComponent("airtype-localapp.log") }
    static var historyDB: URL { root.appendingPathComponent("history.sqlite") }

    static var whisperModels: URL { root.appendingPathComponent("models/whisper", isDirectory: true) }
    static var asrModels: URL { root.appendingPathComponent("models/asr", isDirectory: true) }
    static var asrRuntime: URL { asrModels.appendingPathComponent("runtime", isDirectory: true) }

    static let sherpaRuntimeName = "sherpa-onnx-v2.0.1-osx-arm64-shared"

    static var sherpaRuntime: URL {
        if let override = ProcessInfo.processInfo.environment["SHERPA_ONNX_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return asrRuntime.appendingPathComponent(sherpaRuntimeName, isDirectory: true)
    }

    /// Move experiment + flat Whisper weights into the unified layout. Safe to call repeatedly.
    @discardableResult
    static func migrateIfNeeded() -> [String] {
        let fm = FileManager.default
        var notes: [String] = []

        do {
            try fm.createDirectory(at: whisperModels, withIntermediateDirectories: true)
            try fm.createDirectory(at: asrModels, withIntermediateDirectories: true)
            try fm.createDirectory(at: asrRuntime, withIntermediateDirectories: true)
        } catch {
            notes.append("Could not create ~/.airtype model dirs: \(error.localizedDescription)")
            return notes
        }

        // Flat Whisper ggml/gguf under ~/.airtype/models → models/whisper
        let modelsRoot = root.appendingPathComponent("models", isDirectory: true)
        if let items = try? fm.contentsOfDirectory(at: modelsRoot, includingPropertiesForKeys: nil) {
            for item in items {
                let name = item.lastPathComponent
                if name == "whisper" || name == "asr" { continue }
                let ext = item.pathExtension.lowercased()
                guard ext == "bin" || ext == "gguf" || name.hasPrefix("ggml-") else { continue }
                let dest = whisperModels.appendingPathComponent(name)
                if fm.fileExists(atPath: dest.path) { continue }
                do {
                    try fm.moveItem(at: item, to: dest)
                    notes.append("Moved Whisper model \(name) → models/whisper/")
                } catch {
                    notes.append("Failed moving \(name): \(error.localizedDescription)")
                }
            }
        }

        // Experiment models → models/asr
        let expModels = experimentRoot.appendingPathComponent("models", isDirectory: true)
        if fm.fileExists(atPath: expModels.path),
           let items = try? fm.contentsOfDirectory(at: expModels, includingPropertiesForKeys: nil) {
            for item in items {
                let dest = asrModels.appendingPathComponent(item.lastPathComponent)
                if fm.fileExists(atPath: dest.path) { continue }
                do {
                    try fm.moveItem(at: item, to: dest)
                    notes.append("Moved ASR \(item.lastPathComponent) → models/asr/")
                } catch {
                    notes.append("Failed moving ASR \(item.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        // Experiment runtime → models/asr/runtime
        let expRuntime = experimentRoot.appendingPathComponent("runtime", isDirectory: true)
        if fm.fileExists(atPath: expRuntime.path),
           let items = try? fm.contentsOfDirectory(at: expRuntime, includingPropertiesForKeys: nil) {
            for item in items {
                let dest = asrRuntime.appendingPathComponent(item.lastPathComponent)
                if fm.fileExists(atPath: dest.path) { continue }
                do {
                    try fm.moveItem(at: item, to: dest)
                    notes.append("Moved runtime \(item.lastPathComponent) → models/asr/runtime/")
                } catch {
                    notes.append("Failed moving runtime \(item.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        // Log + hotwords
        let expLog = experimentRoot.appendingPathComponent("airtype-localapp.log")
        if fm.fileExists(atPath: expLog.path), !fm.fileExists(atPath: localAppLog.path) {
            try? fm.moveItem(at: expLog, to: localAppLog)
            notes.append("Moved localapp log → ~/.airtype/")
        }
        for name in ["qwen3-hotwords.txt", "funasr-hotwords.txt"] {
            let src = experimentRoot.appendingPathComponent(name)
            let dest = root.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dest.path) {
                try? fm.moveItem(at: src, to: dest)
                notes.append("Moved \(name) → ~/.airtype/")
            }
        }

        return notes
    }

    /// Rewrite known legacy path strings inside a loaded JSON config document.
    static func rewriteLegacyPaths(in text: inout String) {
        let replacements: [(String, String)] = [
            ("~/.airtype-experiment/models", "~/.airtype/models/asr"),
            ("$HOME/.airtype-experiment/models", "~/.airtype/models/asr"),
            ("~/.airtype-experiment/runtime", "~/.airtype/models/asr/runtime"),
            ("\"model_dir\": \"~/.airtype/models\"", "\"model_dir\": \"~/.airtype/models/whisper\""),
        ]
        for (old, new) in replacements {
            text = text.replacingOccurrences(of: old, with: new)
        }
    }
}
