import Foundation
import Darwin

final class BackendProcessManager {
    private var process: Process?

    func startIfNeeded(config: AirTypeConfig, projectRoot: URL?) {
        guard config.backend.mode.lowercased() != "remote" else {
            Logger.shared.log("Using remote WebUI endpoint: \(config.backend.selectedEndpoint)")
            return
        }

        guard isLocalEndpoint(config.backend.selectedEndpoint) else {
            Logger.shared.log("Using non-local WebUI endpoint: \(config.backend.selectedEndpoint)")
            return
        }

        if isBackendReady(endpoint: config.backend.selectedEndpoint) {
            Logger.shared.log("WebUI already running: \(config.backend.selectedEndpoint)")
            return
        }

        guard let projectRoot else {
            Logger.shared.log("Could not find project root; cannot start local WebUI")
            return
        }

        let python = projectRoot.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            Logger.shared.log("Python venv not found; run ./scripts/setup.sh first")
            return
        }

        let port = URLComponents(string: config.backend.selectedEndpoint)?.port ?? 8003
        let backendDir = projectRoot.appendingPathComponent("source/webui")
        let process = Process()
        process.executableURL = python
        process.currentDirectoryURL = backendDir
        process.arguments = [
            "-m",
            "uvicorn",
            "app.main:app",
            "--host",
            "127.0.0.1",
            "--port",
            String(port)
        ]

        do {
            try process.run()
            self.process = process
            Logger.shared.log("Started local WebUI: \(config.backend.selectedEndpoint)")
        } catch {
            Logger.shared.log("Could not start local WebUI: \(error)")
            return
        }

        waitForBackend(endpoint: config.backend.selectedEndpoint, timeoutSeconds: 8)
    }

    func stop() {
        guard let process, process.isRunning else { return }
        let backendPID = process.processIdentifier
        let descendantPIDs = descendantPIDs(of: backendPID)
        if descendantPIDs.isEmpty {
            Logger.shared.log("Stopping local WebUI: pid=\(backendPID)")
        } else {
            Logger.shared.log(
                "Stopping local WebUI: pid=\(backendPID), descendant_pids=\(descendantPIDs.map(String.init).joined(separator: ","))"
            )
        }

        process.terminate()
        if !waitForExit(process, timeoutSeconds: 8) {
            Logger.shared.log("WebUI did not exit after SIGTERM; sending SIGKILL: pid=\(backendPID)")
            kill(backendPID, SIGKILL)
            _ = waitForExit(process, timeoutSeconds: 3)
        }

        terminateDescendants(descendantPIDs)
        self.process = nil
    }

    private func terminateDescendants(_ pids: [pid_t]) {
        let livePIDs = pids.filter { isProcessRunning($0) }
        if livePIDs.isEmpty {
            return
        }

        Logger.shared.log("Stopping WebUI child processes: pids=\(livePIDs.map(String.init).joined(separator: ","))")
        for pid in livePIDs {
            kill(pid, SIGTERM)
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if livePIDs.allSatisfy({ !isProcessRunning($0) }) {
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        let remaining = livePIDs.filter { isProcessRunning($0) }
        if !remaining.isEmpty {
            Logger.shared.log("Force killing WebUI child processes: pids=\(remaining.map(String.init).joined(separator: ","))")
            for pid in remaining {
                kill(pid, SIGKILL)
            }
        }
    }

    private func waitForExit(_ process: Process, timeoutSeconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !process.isRunning {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return !process.isRunning
    }

    private func descendantPIDs(of pid: pid_t) -> [pid_t] {
        let directChildren = childPIDs(of: pid)
        return directChildren + directChildren.flatMap { descendantPIDs(of: $0) }
    }

    private func childPIDs(of pid: pid_t) -> [pid_t] {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", String(pid)]
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func isProcessRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private func isLocalEndpoint(_ endpoint: String) -> Bool {
        guard let host = URLComponents(string: endpoint)?.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    @discardableResult
    private func waitForBackend(endpoint: String, timeoutSeconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if isBackendReady(endpoint: endpoint) {
                Logger.shared.log("WebUI ready: \(endpoint)")
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        Logger.shared.log("WebUI still starting: \(endpoint)")
        return isBackendReady(endpoint: endpoint)
    }

    private func isBackendReady(endpoint: String) -> Bool {
        guard let url = URL(string: endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/health") else {
            return false
        }

        var ready = false
        let semaphore = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.35
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                ready = true
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 0.5)
        return ready
    }
}
