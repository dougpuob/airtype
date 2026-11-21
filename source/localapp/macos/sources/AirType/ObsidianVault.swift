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
        ObsidianNoteFiles.safeName(text)
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
    ///
    /// When `reuseIdentical` is true, an existing file in that name sequence whose
    /// contents already equal `note` is returned instead of creating another file.
    @discardableResult
    static func writeNote(title: String, note: String, config: ObsidianConfig, reuseIdentical: Bool = false) throws -> URL {
        let dir = try targetDirectory(config: config)
        do {
            return try ObsidianNoteFiles.place(markdown: note, title: title, directory: dir, reuseIdentical: reuseIdentical)
        } catch {
            throw ObsidianVaultError.writeFailed(error.localizedDescription)
        }
    }
}
