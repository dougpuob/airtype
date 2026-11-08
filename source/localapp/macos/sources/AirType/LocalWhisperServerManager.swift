import Foundation

/// Owns the localapp-managed `whisper-server` process for `[localapp.local-whisper]`.
@MainActor
final class LocalWhisperServerManager {
    enum ManagerError: LocalizedError {
        case alreadyRunning(pid: Int32)
        case missingBinary
        case missingModel(String)
        case invalidArgs(String)
        case startFailed(String)
        case exitedEarly(String)
        case notReady(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning(let pid): return "Already running (pid \(pid))."
            case .missingBinary: return "whisper-server binary not found; set File Path."
            case .missingModel(let path): return "Model not found: \(path)"
            case .invalidArgs(let detail): return "Invalid Advanced Args: \(detail)"
            case .startFailed(let detail): return "Failed to start whisper-server: \(detail)"
            case .exitedEarly(let detail): return "whisper-server exited early: \(detail)"
            case .notReady(let detail): return "whisper-server did not become ready: \(detail)"
            }
        }
    }

    private var process: Process?
    private var outputPipe: Pipe?
    private var outputTail: [String] = []
    private var endpointHost = "127.0.0.1"
    private var endpointPort = 8080
    private var starting = false

    var isRunning: Bool {
        guard let process else { return false }
        return process.isRunning
    }

    var pid: Int32? {
        guard isRunning, let process else { return nil }
        return process.processIdentifier
    }

    var statusText: String {
        if starting { return "starting…" }
        if let pid {
            return "running · pid \(pid) · \(endpointHost):\(endpointPort)"
        }
        return "stopped"
    }

    /// Starts whisper-server with the given config. No-op error if already running the same managed process.
    func start(_ config: LocalWhisperServiceConfig) async throws {
        if isRunning, let pid {
            throw ManagerError.alreadyRunning(pid: pid)
        }
        stopManagedProcess(forceKill: true)

        let bin = Self.resolveBinary(config.serverBin)
        guard let bin else { throw ManagerError.missingBinary }

        let modelPath = Self.modelPath(dir: config.modelDir, file: config.modelFilename)
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw ManagerError.missingModel(modelPath)
        }

        let extraArgs: [String]
        do {
            extraArgs = try Self.splitArgs(config.serverArgs)
        } catch {
            throw ManagerError.invalidArgs(error.localizedDescription)
        }

        let host = config.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "127.0.0.1"
            : config.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = config.port
        var arguments = [
            "-m", modelPath,
            "--host", host,
            "--port", String(port),
            "-t", String(max(1, config.maxThreads)),
            "-l", Self.whisperLanguage(config.language),
            "-bs", String(max(1, config.beam))
        ]
        if config.maxGpu == 0 {
            arguments.append("--no-gpu")
        }
        if config.noTimestamps {
            arguments.append("--no-timestamps")
        }
        let prompt = config.vocabularyPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            arguments += ["--prompt", prompt]
        }
        arguments += extraArgs

        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        outputPipe = pipe
        outputTail = []

        starting = true
        endpointHost = host
        endpointPort = port
        defer { starting = false }

        Logger.shared.log(
            "LocalWhisper: starting bin=\(bin) model=\(modelPath) endpoint=http://\(host):\(port) args=\(arguments.joined(separator: " "))"
        )

        do {
            try process.run()
        } catch {
            self.process = nil
            outputPipe = nil
            throw ManagerError.startFailed(error.localizedDescription)
        }
        self.process = process
        Self.attachLogReader(pipe: pipe, manager: self)

        do {
            try await waitUntilReady(host: host, port: port, process: process)
        } catch {
            stopManagedProcess(forceKill: true)
            throw error
        }

        Logger.shared.log("LocalWhisper: started pid=\(process.processIdentifier) endpoint=http://\(host):\(port)")
    }

    func stop() {
        guard process != nil else { return }
        let pid = process?.processIdentifier
        Logger.shared.log("LocalWhisper: stopping managed whisper-server pid=\(pid.map(String.init) ?? "?")")
        stopManagedProcess(forceKill: false)
    }

    /// Ensure running state matches `enabled` after Apply/Save or app launch.
    /// Returns an error message when an enabled sync fails to start.
    @discardableResult
    func sync(to config: LocalWhisperServiceConfig) async -> String? {
        if config.enabled {
            if isRunning { return nil }
            do {
                try await start(config)
                return nil
            } catch {
                let message = error.localizedDescription
                Logger.shared.log("LocalWhisper: sync start failed: \(message)")
                return message
            }
        }
        if isRunning {
            stop()
        }
        return nil
    }

    // MARK: - Internals

    private func stopManagedProcess(forceKill: Bool) {
        guard let process else {
            self.process = nil
            outputPipe = nil
            return
        }
        if process.isRunning {
            if !forceKill {
                process.terminate()
                let deadline = Date().addingTimeInterval(5)
                while process.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        self.process = nil
        outputPipe = nil
    }

    private func waitUntilReady(host: String, port: Int, process: Process) async throws {
        let endpoint = URL(string: "http://\(host):\(port)/")!
        var lastError = "no response"
        for _ in 0..<60 {
            if !process.isRunning {
                let tail = outputTail.suffix(12).joined(separator: "\n")
                throw ManagerError.exitedEarly(tail.isEmpty ? "exit \(process.terminationStatus)" : tail)
            }
            do {
                var request = URLRequest(url: endpoint, timeoutInterval: 1)
                request.httpMethod = "GET"
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode < 500 {
                    return
                }
                lastError = "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            } catch {
                lastError = error.localizedDescription
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw ManagerError.notReady(lastError)
    }

    private static func attachLogReader(pipe: Pipe, manager: LocalWhisperServerManager) {
        pipe.fileHandleForReading.readabilityHandler = { [weak manager] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else {
                if data.isEmpty {
                    handle.readabilityHandler = nil
                }
                return
            }
            let lines = chunk.split(whereSeparator: \.isNewline).map(String.init)
            Task { @MainActor in
                guard let manager else { return }
                for line in lines where !line.isEmpty {
                    manager.outputTail.append(line)
                    if manager.outputTail.count > 80 {
                        manager.outputTail.removeFirst(manager.outputTail.count - 80)
                    }
                    Logger.shared.log("whisper-server: \(line)")
                }
            }
        }
    }

    static func resolveBinary(_ configured: String) -> String? {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        let fm = FileManager.default
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) { return expanded }
        }
        for candidate in ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"] {
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func modelPath(dir: String, file: String) -> String {
        let expandedDir = (dir as NSString).expandingTildeInPath
        let name = file.trimmingCharacters(in: .whitespacesAndNewlines)
        return (expandedDir as NSString).appendingPathComponent(name)
    }

    static func whisperLanguage(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "zh-tw", "zh-cn", "zh-hk", "zh-hans", "zh-hant": return "zh"
        case "auto", "auto-tw", "auto-cn", "auto_tw", "auto_cn": return "auto"
        default: return value.isEmpty ? "zh" : value
        }
    }

    /// Minimal shell-like split for Advanced Args (supports "double" and 'single' quotes).
    static func splitArgs(_ raw: String) throws -> [String] {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return [] }
        var args: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for ch in input {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" {
                escaped = true
                continue
            }
            if let q = quote {
                if ch == q {
                    quote = nil
                } else {
                    current.append(ch)
                }
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                continue
            }
            if ch.isWhitespace {
                if !current.isEmpty {
                    args.append(current)
                    current = ""
                }
                continue
            }
            current.append(ch)
        }
        if quote != nil {
            throw ManagerError.invalidArgs("unclosed quote")
        }
        if escaped {
            current.append("\\")
        }
        if !current.isEmpty {
            args.append(current)
        }
        return args
    }
}
