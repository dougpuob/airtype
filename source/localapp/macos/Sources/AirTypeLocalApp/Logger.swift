import Foundation

final class Logger {
    static let shared = Logger()

    private let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".airtype-experiment/airtype-localapp.log")

    private init() {}

    func startNewRunLog() {
        let now = ISO8601DateFormatter().string(from: Date())
        let bundle = Bundle.main
        let process = ProcessInfo.processInfo
        let info = bundle.infoDictionary ?? [:]
        let appName = (info["CFBundleName"] as? String) ?? process.processName
        let bundleIdentifier = bundle.bundleIdentifier ?? "unknown"
        let version = (info["CFBundleShortVersionString"] as? String) ?? "unknown"
        let build = (info["CFBundleVersion"] as? String) ?? "unknown"
        let executablePath = bundle.executableURL?.path ?? CommandLine.arguments.first ?? "unknown"
        let bundlePath = bundle.bundleURL.path
        let workingDirectory = FileManager.default.currentDirectoryPath
        let arguments = CommandLine.arguments.joined(separator: " ")

        let lines = [
            "[AirTypeLocalApp] Run started at \(now)",
            "[AirTypeLocalApp] Executable: name=\(appName), bundle_id=\(bundleIdentifier), version=\(version), build=\(build)",
            "[AirTypeLocalApp] Executable path: \(executablePath)",
            "[AirTypeLocalApp] Bundle path: \(bundlePath)",
            "[AirTypeLocalApp] Process: pid=\(process.processIdentifier), os=\(process.operatingSystemVersionString)",
            "[AirTypeLocalApp] Working directory: \(workingDirectory)",
            "[AirTypeLocalApp] Arguments: \(arguments)"
        ]
        let text = lines.joined(separator: "\n") + "\n"
        print(text, terminator: "")
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: path, atomically: true, encoding: .utf8)
        } catch {
            print("[AirTypeLocalApp] log write failed: \(error)")
        }
    }

    func log(_ message: String) {
        let text = "[AirTypeLocalApp] \(message)"
        print(text)
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let line = text + "\n"
            if FileManager.default.fileExists(atPath: path.path),
               let handle = try? FileHandle(forWritingTo: path) {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } else {
                try line.write(to: path, atomically: true, encoding: .utf8)
            }
        } catch {
            print("[AirTypeLocalApp] log write failed: \(error)")
        }
    }

    func blankLine() {
        print("")
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: path.path),
               let handle = try? FileHandle(forWritingTo: path) {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("\n".utf8))
                try handle.close()
            } else {
                try "\n".write(to: path, atomically: true, encoding: .utf8)
            }
        } catch {
            print("[AirTypeLocalApp] log write failed: \(error)")
        }
    }

    func marker(_ title: String, details: String) {
        log("========== \(title) START ==========")
        if !details.isEmpty {
            log("\(title) context: \(details)")
        }
    }
}
