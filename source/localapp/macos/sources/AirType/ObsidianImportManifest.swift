import Foundation

/// Manifest downloaded by `airtype://obsidian-import?url=…`.
struct ObsidianImportManifest: Decodable {
    var schemaVersion: Int
    var kind: String
    var exportedAt: String?
    var source: Source?
    var vaultFolder: String?
    var notes: [Note]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case kind
        case exportedAt = "exported_at"
        case source
        case vaultFolder = "vault_folder"
        case notes
    }

    struct Source: Decodable {
        var app: String?
        var baseURL: String?
        enum CodingKeys: String, CodingKey {
            case app
            case baseURL = "base_url"
        }
    }

    struct Note: Decodable {
        var id: String
        var title: String
        var markdown: String
        var createdAt: String?
        var tags: [String]?
        var folder: String?
        var sourceURL: String?
        var markSaved: MarkSaved?

        enum CodingKeys: String, CodingKey {
            case id, title, markdown, tags, folder
            case createdAt = "created_at"
            case sourceURL = "source_url"
            case markSaved = "mark_saved"
        }
    }

    struct MarkSaved: Decodable {
        var method: String?
        var url: String
    }
}
