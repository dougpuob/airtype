import Foundation

enum ObsidianVaultError: LocalizedError {
    case emptyVaultPath
    case vaultMissing(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyVaultPath:
            return "Obsidian vault path is empty. Set it in Settings ▸ Obsidian."
        case .vaultMissing(let path):
            return "Obsidian vault folder not found: \(path)"
        case .writeFailed(let detail):
            return detail
        }
    }
}

enum ObsidianVault {
    /// Sanitize a note title for use as a filename.
    static func safeName(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(
            of: #"[\\/:*?"<>|;；：\x00-\x1f]"#,
            with: " ",
            options: .regularExpression
        )
        return cleaned
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Expand `~` and return the folder where notes should be written.
    static func targetDirectory(config: ObsidianConfig) throws -> URL {
        let raw = config.vaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw ObsidianVaultError.emptyVaultPath }
        var path = (raw as NSString).expandingTildeInPath
        let folder = config.defaultFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !folder.isEmpty {
            for part in folder.split(separator: "/") {
                let name = safeName(String(part))
                if !name.isEmpty { path = (path as NSString).appendingPathComponent(name) }
            }
        }
        var isDir: ObjCBool = false
        let vaultRoot = (raw as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: vaultRoot, isDirectory: &isDir), isDir.boolValue else {
            throw ObsidianVaultError.vaultMissing(vaultRoot)
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Write `note` as `{title}.md` (or `{title} N.md` if taken). Returns the file URL.
    @discardableResult
    static func writeNote(title: String, note: String, config: ObsidianConfig) throws -> URL {
        let dir = try targetDirectory(config: config)
        let base = safeName(title).isEmpty ? "Untitled" : safeName(title)
        var url = dir.appendingPathComponent("\(base).md")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(counter).md")
            counter += 1
        }
        do {
            try note.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ObsidianVaultError.writeFailed(error.localizedDescription)
        }
        return url
    }
}
