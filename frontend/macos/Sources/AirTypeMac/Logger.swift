import Foundation

final class Logger {
    static let shared = Logger()

    private let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".airtype/airtype-macos.log")

    private init() {}

    func log(_ message: String) {
        let text = "[AirTypeMac] \(message)"
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
            print("[AirTypeMac] log write failed: \(error)")
        }
    }
}
