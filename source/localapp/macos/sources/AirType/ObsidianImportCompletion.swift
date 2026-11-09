import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Completion reporting for `airtype://obsidian-import`.
//
// Notes are written locally first. The batch callback is then POSTed to the
// WebUI that actually served the manifest, and the response is parsed before
// anything is described as confirmed. A failed callback is stored so it can be
// retried without writing the notes again. Tokens and Basic credentials are
// kept out of the strings this file returns for logs and alerts.

enum ObsidianNoteFileError: LocalizedError {
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let detail):
            return detail
        }
    }
}

enum ObsidianNoteFiles {
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

    /// Write `markdown` into `directory`, or return an existing identical file.
    static func place(markdown: String, title: String, directory: URL, reuseIdentical: Bool) throws -> URL {
        let base = safeName(title).isEmpty ? "Untitled" : safeName(title)
        var index = 1
        while index < 10_000 {
            let name = index == 1 ? "\(base).md" : "\(base) \(index).md"
            let url = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                do {
                    try markdown.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    throw ObsidianNoteFileError.writeFailed(error.localizedDescription)
                }
                return url
            }
            if reuseIdentical, let existing = try? String(contentsOf: url, encoding: .utf8), existing == markdown {
                return url
            }
            index += 1
        }
        throw ObsidianNoteFileError.writeFailed("Too many notes named \(base)")
    }
}

enum SHA256Hex {
    static func hex(_ data: Data) -> String {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }

        var hash: [UInt32] = [
            0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
            0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
        ]

        func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
            (value >> count) | (value << (32 - count))
        }

        var offset = 0
        while offset < message.count {
            var words = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let start = offset + index * 4
                words[index] = (UInt32(message[start]) << 24)
                    | (UInt32(message[start + 1]) << 16)
                    | (UInt32(message[start + 2]) << 8)
                    | UInt32(message[start + 3])
            }
            for index in 16..<64 {
                let small = rotate(words[index - 15], 7) ^ rotate(words[index - 15], 18) ^ (words[index - 15] >> 3)
                let large = rotate(words[index - 2], 17) ^ rotate(words[index - 2], 19) ^ (words[index - 2] >> 10)
                words[index] = words[index - 16] &+ small &+ words[index - 7] &+ large
            }
            var a = hash[0], b = hash[1], c = hash[2], d = hash[3]
            var e = hash[4], f = hash[5], g = hash[6], h = hash[7]
            for index in 0..<64 {
                let sum1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choose = (e & f) ^ ((~e) & g)
                let temp1 = h &+ sum1 &+ choose &+ Self.roundConstants[index] &+ words[index]
                let sum0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = sum0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            hash[0] = hash[0] &+ a
            hash[1] = hash[1] &+ b
            hash[2] = hash[2] &+ c
            hash[3] = hash[3] &+ d
            hash[4] = hash[4] &+ e
            hash[5] = hash[5] &+ f
            hash[6] = hash[6] &+ g
            hash[7] = hash[7] &+ h
            offset += 64
        }
        return hash.map { String(format: "%08x", $0) }.joined()
    }

    private static let roundConstants: [UInt32] = [
        0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
        0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
        0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
        0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
        0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
        0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
        0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
        0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2
    ]
}

struct ObsidianURLOrigin: Equatable {
    var scheme: String
    var host: String
    var port: Int
}

struct ObsidianRejectedNote {
    var id: String
    var reason: String
}

struct ObsidianWriteFailure {
    var id: String
    var title: String
    var message: String
}

struct ObsidianImportedNote {
    var id: String
    var title: String
    var path: String
    var status: String
    var message: String?
}

enum ObsidianAckOutcome: String {
    case confirmed
    case partial
    case httpError
    case transport
    case invalidResponse
    case originMismatch
    case noCallback
    case receiptMissing
}

struct ObsidianImportReport {
    var exportID: String
    var writtenIDs: [String]
    var writeFailures: [ObsidianWriteFailure]
    var confirmedIDs: [String]
    var rejected: [ObsidianRejectedNote]
    var outcome: ObsidianAckOutcome
    var httpStatus: Int?
    var callbackOrigin: String
    var configuredBackendOrigin: String
    var authAttached: Bool
    var detail: String
    var diagnosticText: String
    var historySourceURL: String
    var canRetryAcknowledgement: Bool
    var items: [ObsidianImportedNote]
}

struct ObsidianImportDialog {
    var title: String
    var message: String
    var offerRetry: Bool

    static func make(_ report: ObsidianImportReport) -> ObsidianImportDialog {
        let written = report.writtenIDs.count
        let confirmed = report.confirmedIDs.count
        let failed = report.writeFailures.count
        var lines = [
            "Notes written: \(written)",
            "WebUI confirmed: \(confirmed)"
        ]
        if failed > 0 {
            lines.append("Local write failures: \(failed)")
        }
        lines.append("")
        lines.append(summarySentence(report))
        if !report.detail.isEmpty {
            lines.append("")
            lines.append(report.detail)
        }
        if !report.writeFailures.isEmpty {
            lines.append("")
            lines.append("Write errors:")
            for failure in report.writeFailures.prefix(3) {
                lines.append("• \(failure.title): \(failure.message)")
            }
        }
        if !report.rejected.isEmpty {
            lines.append("")
            lines.append("WebUI left these unsaved:")
            for rejected in report.rejected.prefix(5) where report.writtenIDs.contains(rejected.id) {
                lines.append("• \(rejected.id): \(reasonText(rejected.reason))")
            }
        }
        let message = ObsidianCompletion.redactSecrets(lines.joined(separator: "\n"))
        return ObsidianImportDialog(title: title(report), message: message, offerRetry: report.canRetryAcknowledgement)
    }

    private static func title(_ report: ObsidianImportReport) -> String {
        switch report.outcome {
        case .confirmed where report.writeFailures.isEmpty:
            return "Imported to Obsidian"
        case .confirmed:
            return "Imported with notes that could not be written"
        case .partial:
            return "Notes written, WebUI confirmed only some"
        case .receiptMissing:
            return "Obsidian acknowledgment receipt missing"
        case .noCallback, .originMismatch, .httpError, .transport, .invalidResponse:
            return report.writtenIDs.isEmpty ? "Obsidian import could not be confirmed" : "Notes written, WebUI not confirmed"
        }
    }

    private static func summarySentence(_ report: ObsidianImportReport) -> String {
        switch report.outcome {
        case .confirmed where report.writeFailures.isEmpty:
            return "The WebUI confirmed every note that was written. Those notes leave the unsaved list."
        case .confirmed:
            return "The WebUI confirmed the notes that were written. Notes that could not be written stay unsaved."
        case .partial:
            return "The vault files were kept. Notes the WebUI did not confirm stay on the unsaved list. Retry acknowledgment sends the same result again and does not write the notes again."
        case .originMismatch:
            return "The completion URL does not belong to the WebUI that served this export. The callback was not sent, and credentials were not attached."
        case .noCallback:
            return "This manifest has no completion callback, so the WebUI was not updated. The vault files were kept."
        case .receiptMissing:
            return "AirType has no local receipt for this export, so it did not guess which notes to confirm."
        case .httpError, .transport, .invalidResponse:
            return "The vault files were kept. The WebUI still lists these notes as unsaved until acknowledgment succeeds. Retry acknowledgment does not write the notes again."
        }
    }

    private static func reasonText(_ reason: String) -> String {
        switch reason {
        case "changed":
            return "the note changed after this export was created"
        case "missing":
            return "the note no longer exists"
        case "not_completed":
            return "the note is not completed"
        case "not_in_export":
            return "the note was not part of this export"
        default:
            return reason
        }
    }
}

struct ObsidianImportReceipt: Codable {
    var exportID: String
    var downloadOrigin: String
    var allowedCallbackOrigin: String
    var historySourceURL: String
    var callbackURL: String
    var callbackAllowed: Bool
    /// `allowed`, `missing`, or `origin_mismatch`.
    var callbackState: String
    var notes: [Note]

    struct Note: Codable {
        var id: String
        var title: String
        var contentSHA256: String
        var path: String
        var status: String
        var message: String?
    }
}

final class ObsidianImportReceiptStore {
    let directory: URL
    private var memory: [String: ObsidianImportReceipt] = [:]

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    func load(exportID: String) -> ObsidianImportReceipt? {
        let key = ObsidianCompletion.safeExportID(exportID)
        if let cached = memory[key] {
            return cached
        }
        let url = fileURL(exportID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let receipt = try? JSONDecoder().decode(ObsidianImportReceipt.self, from: data) else { return nil }
        memory[key] = receipt
        return receipt
    }

    func save(_ receipt: ObsidianImportReceipt) throws {
        let data = try JSONEncoder().encode(receipt)
        let url = fileURL(receipt.exportID)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        memory[ObsidianCompletion.safeExportID(receipt.exportID)] = receipt
    }

    func fileURL(_ exportID: String) -> URL {
        directory.appendingPathComponent("\(ObsidianCompletion.safeExportID(exportID)).json")
    }
}

struct ObsidianImportEngine {
    var receipts: ObsidianImportReceiptStore
    var send: (URLRequest) async throws -> (status: Int, body: Data)
    var writeNote: (_ title: String, _ markdown: String, _ folder: String?) throws -> URL
    var readFile: (_ path: String) -> Data?

    func importManifest(
        manifest: ObsidianImportManifest,
        downloadURL: URL,
        finalDownloadURL: URL?,
        configuredEndpoint: String,
        authEnabled: Bool,
        username: String,
        password: String
    ) async -> ObsidianImportReport {
        let exportID = ObsidianCompletion.exportID(manifest: manifest, downloadURL: downloadURL)
        var receipt = receipts.load(exportID: exportID) ?? ObsidianImportReceipt(
            exportID: exportID,
            downloadOrigin: "",
            allowedCallbackOrigin: "",
            historySourceURL: "",
            callbackURL: "",
            callbackAllowed: false,
            callbackState: "missing",
            notes: []
        )
        ObsidianCompletion.describeDownload(&receipt, downloadURL: downloadURL, finalDownloadURL: finalDownloadURL, manifest: manifest)
        let secrets = ObsidianCompletion.secrets(downloadURL: downloadURL, callbackURL: receipt.callbackURL, password: password)
        for note in manifest.notes {
            let markdown = note.markdown
            let digest = SHA256Hex.hex(Data(markdown.utf8))
            if let existing = receipt.notes.first(where: { $0.id == note.id && $0.status == "written" }),
               existing.contentSHA256 == digest,
               let bytes = readFile(existing.path),
               SHA256Hex.hex(bytes) == digest {
                continue
            }
            let folder = resolvedFolder(note: note, manifest: manifest)
            do {
                let url = try writeNote(note.title, markdown, folder)
                upsert(&receipt, note: note, digest: digest, path: url.path, status: "written", message: nil)
            } catch {
                upsert(
                    &receipt,
                    note: note,
                    digest: digest,
                    path: "",
                    status: "failed",
                    message: ObsidianCompletion.redactSecrets(error.localizedDescription, extraSecrets: secrets)
                )
            }
            try? receipts.save(receipt)
        }
        try? receipts.save(receipt)
        return await acknowledge(
            receipt,
            configuredEndpoint: configuredEndpoint,
            authEnabled: authEnabled,
            username: username,
            password: password
        )
    }

    func retryAcknowledgement(
        exportID: String,
        configuredEndpoint: String,
        authEnabled: Bool,
        username: String,
        password: String
    ) async -> ObsidianImportReport {
        guard let receipt = receipts.load(exportID: exportID) else {
            let detail = "No local receipt for export \(ObsidianCompletion.safeExportID(exportID))."
            let diagnostic = ObsidianCompletion.diagnostic(
                exportID: exportID,
                written: 0,
                failed: 0,
                confirmed: 0,
                callbackOrigin: "",
                configuredBackendOrigin: ObsidianCompletion.originDescription(ofEndpoint: configuredEndpoint),
                authAttached: false,
                httpStatus: nil,
                result: ObsidianAckOutcome.receiptMissing.rawValue,
                detail: detail,
                secrets: ObsidianCompletion.secrets(downloadURL: nil, callbackURL: nil, password: password)
            )
            return ObsidianImportReport(
                exportID: exportID,
                writtenIDs: [],
                writeFailures: [],
                confirmedIDs: [],
                rejected: [],
                outcome: .receiptMissing,
                httpStatus: nil,
                callbackOrigin: "",
                configuredBackendOrigin: ObsidianCompletion.originDescription(ofEndpoint: configuredEndpoint),
                authAttached: false,
                detail: detail,
                diagnosticText: diagnostic,
                historySourceURL: "",
                canRetryAcknowledgement: false,
                items: []
            )
        }
        return await acknowledge(
            receipt,
            configuredEndpoint: configuredEndpoint,
            authEnabled: authEnabled,
            username: username,
            password: password
        )
    }

    private func acknowledge(
        _ receipt: ObsidianImportReceipt,
        configuredEndpoint: String,
        authEnabled: Bool,
        username: String,
        password: String
    ) async -> ObsidianImportReport {
        let secrets = ObsidianCompletion.secrets(downloadURL: nil, callbackURL: receipt.callbackURL, password: password)
        let written = receipt.notes.filter { $0.status == "written" }
        let failedNotes = receipt.notes.filter { $0.status == "failed" }
        let configuredOrigin = ObsidianCompletion.originDescription(ofEndpoint: configuredEndpoint)
        var httpStatus: Int?
        var rejected: [ObsidianRejectedNote] = []
        var confirmed: [String] = []
        var outcome: ObsidianAckOutcome = .noCallback
        var detail = ""
        var authAttached = false
        var callbackOrigin = receipt.allowedCallbackOrigin

        if receipt.callbackState != "allowed" || receipt.callbackURL.isEmpty {
            if receipt.callbackState == "origin_mismatch" {
                outcome = .originMismatch
                detail = "Refused to call a completion URL outside \(receipt.downloadOrigin)."
            } else {
                outcome = .noCallback
                detail = "The manifest did not include a usable completion callback."
            }
        } else if let callbackURL = URL(string: receipt.callbackURL),
                  let callback = ObsidianCompletion.origin(of: callbackURL),
                  ObsidianCompletion.describe(callback) == receipt.allowedCallbackOrigin {
            callbackOrigin = ObsidianCompletion.describe(callback)
            let authorization = ObsidianCompletion.basicAuthorization(
                enabled: authEnabled,
                username: username,
                password: password,
                endpoint: configuredEndpoint,
                callback: callbackURL
            )
            authAttached = authorization != nil
            let request = ObsidianCompletion.makeRequest(
                url: callbackURL,
                savedIDs: written.map(\.id),
                failedIDs: failedNotes.map(\.id),
                authorization: authorization
            )
            do {
                let response = try await send(request)
                httpStatus = response.status
                switch ObsidianCompletion.parseConfirmation(status: response.status, body: response.body) {
                case .success(let confirmation):
                    let writtenIDs = written.map(\.id)
                    confirmed = writtenIDs.filter { confirmation.savedIDs.contains($0) }
                    rejected = confirmation.rejected
                    let missing = writtenIDs.filter { !confirmation.savedIDs.contains($0) }
                    if missing.isEmpty {
                        outcome = .confirmed
                        detail = "The WebUI confirmed \(confirmed.count) written note\(confirmed.count == 1 ? "" : "s")."
                    } else {
                        outcome = .partial
                        detail = "The WebUI confirmed \(confirmed.count) of \(writtenIDs.count) written notes."
                    }
                case .failure(let failure):
                    outcome = failure.outcome
                    detail = failure.detail
                }
            } catch {
                outcome = .transport
                detail = "Could not reach the WebUI that served this export. \(error.localizedDescription)"
            }
        } else {
            outcome = .originMismatch
            detail = "The stored completion URL does not match the WebUI that served this export."
        }

        detail = ObsidianCompletion.redactSecrets(detail, extraSecrets: secrets)
        let diagnostic = ObsidianCompletion.diagnostic(
            exportID: receipt.exportID,
            written: written.count,
            failed: failedNotes.count,
            confirmed: confirmed.count,
            callbackOrigin: callbackOrigin,
            configuredBackendOrigin: configuredOrigin,
            authAttached: authAttached,
            httpStatus: httpStatus,
            result: outcome.rawValue,
            detail: detail,
            secrets: secrets
        )
        let items = receipt.notes.map { note -> ObsidianImportedNote in
            let status: String
            if note.status == "failed" {
                status = "failed"
            } else if confirmed.contains(note.id) {
                status = "confirmed"
            } else {
                status = "written_unconfirmed"
            }
            return ObsidianImportedNote(id: note.id, title: note.title, path: note.path, status: status, message: note.message)
        }
        let writtenIDs = written.map(\.id)
        let canRetry = receipt.callbackAllowed && !receipt.callbackURL.isEmpty && Set(confirmed) != Set(writtenIDs)
        return ObsidianImportReport(
            exportID: receipt.exportID,
            writtenIDs: writtenIDs,
            writeFailures: failedNotes.map { ObsidianWriteFailure(id: $0.id, title: $0.title, message: $0.message ?? "Could not write the note") },
            confirmedIDs: confirmed,
            rejected: rejected.filter { writtenIDs.contains($0.id) },
            outcome: outcome,
            httpStatus: httpStatus,
            callbackOrigin: callbackOrigin,
            configuredBackendOrigin: configuredOrigin,
            authAttached: authAttached,
            detail: detail,
            diagnosticText: diagnostic,
            historySourceURL: receipt.historySourceURL,
            canRetryAcknowledgement: canRetry && outcome != .originMismatch && outcome != .noCallback,
            items: items
        )
    }

    private func resolvedFolder(note: ObsidianImportManifest.Note, manifest: ObsidianImportManifest) -> String? {
        if let folder = note.folder?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty {
            return folder
        }
        if let folder = manifest.vaultFolder?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty {
            return folder
        }
        return nil
    }

    private func upsert(
        _ receipt: inout ObsidianImportReceipt,
        note: ObsidianImportManifest.Note,
        digest: String,
        path: String,
        status: String,
        message: String?
    ) {
        let stored = ObsidianImportReceipt.Note(
            id: note.id,
            title: note.title,
            contentSHA256: digest,
            path: path,
            status: status,
            message: message
        )
        if let index = receipt.notes.firstIndex(where: { $0.id == note.id }) {
            receipt.notes[index] = stored
        } else {
            receipt.notes.append(stored)
        }
    }
}

enum ObsidianCompletion {
    struct Confirmation {
        var savedIDs: [String]
        var rejected: [ObsidianRejectedNote]
    }

    struct ParseFailure: Error {
        var outcome: ObsidianAckOutcome
        var detail: String
    }

    static func safeExportID(_ exportID: String) -> String {
        let cleaned = exportID.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
        }
        let text = String(String.UnicodeScalarView(cleaned))
        return text.isEmpty ? "unknown" : text
    }

    static func exportID(manifest: ObsidianImportManifest, downloadURL: URL) -> String {
        if let value = manifest.exportID?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        return exportID(from: downloadURL) ?? "unknown"
    }

    static func exportID(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "obsidian-exports"), index + 1 < parts.count else { return nil }
        let value = parts[index + 1]
        return value == "complete" || value.isEmpty ? nil : value
    }

    static func origin(of url: URL) -> ObsidianURLOrigin? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return ObsidianURLOrigin(scheme: scheme, host: host, port: port)
    }

    static func describe(_ origin: ObsidianURLOrigin) -> String {
        let host = origin.host.contains(":") ? "[\(origin.host)]" : origin.host
        return "\(origin.scheme)://\(host):\(origin.port)"
    }

    static func originDescription(ofEndpoint endpoint: String) -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let origin = origin(of: url) else {
            return trimmed.isEmpty ? "unconfigured" : "unparsed"
        }
        return describe(origin)
    }

    static func redactedURL(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return origin(of: url).map(describe) ?? "unknown"
        }
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.string ?? (origin(of: url).map(describe) ?? "unknown")
    }

    static func redactSecrets(_ text: String, extraSecrets: [String] = []) -> String {
        var output = text
        if let regex = try? NSRegularExpression(pattern: #"(?i)(^|[&?\s"'])(token=)[^&\s"']+"#) {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: "$1$2[redacted]")
        }
        if let regex = try? NSRegularExpression(pattern: #"(?i)(authorization:\s*basic\s+)[A-Za-z0-9+/=]+"#) {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: "$1[redacted]")
        }
        for secret in extraSecrets where secret.count >= 4 {
            output = output.replacingOccurrences(of: secret, with: "[redacted]")
        }
        return output
    }

    static func secrets(downloadURL: URL?, callbackURL: String?, password: String) -> [String] {
        var values: [String] = []
        if password.count >= 4 { values.append(password) }
        for url in [downloadURL, callbackURL.flatMap(URL.init(string:))] {
            guard let url, let token = queryValue(url, named: "token"), token.count >= 4 else { continue }
            values.append(token)
        }
        return values
    }

    static func queryValue(_ url: URL, named name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    /// Callback URL pinned to the host that served the manifest.
    ///
    /// The path and query of the manifest's completion URL are kept. The scheme
    /// and port are taken from the final download response when that response
    /// stayed on the same host, so an HTTP-to-HTTPS redirect is not repeated as
    /// a POST (URLSession would turn that redirected POST into a GET). A completion
    /// URL on any other host is refused.
    static func pinnedCallbackURL(complete: URL, download: URL, finalDownload: URL?) -> URL? {
        let resolved: URL
        if complete.scheme == nil || complete.host == nil {
            guard let absolute = URL(string: complete.relativeString, relativeTo: finalDownload ?? download)?.absoluteURL else {
                return nil
            }
            resolved = absolute
        } else {
            resolved = complete
        }
        guard let completeOrigin = origin(of: resolved), let downloadOrigin = origin(of: download) else { return nil }
        let servedOrigin = finalDownload.flatMap { origin(of: $0) }
        guard completeOrigin == downloadOrigin || completeOrigin == servedOrigin else { return nil }
        var target = completeOrigin
        if let servedOrigin, servedOrigin.host == completeOrigin.host {
            target.scheme = servedOrigin.scheme
            target.port = servedOrigin.port
        }
        guard var parts = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = target.scheme
        parts.host = target.host
        let defaultPort = target.scheme == "https" ? 443 : 80
        parts.port = target.port == defaultPort ? nil : target.port
        parts.user = nil
        parts.password = nil
        return parts.url
    }

    static func describeDownload(
        _ receipt: inout ObsidianImportReceipt,
        downloadURL: URL,
        finalDownloadURL: URL?,
        manifest: ObsidianImportManifest
    ) {
        receipt.historySourceURL = redactedURL(downloadURL)
        if let downloadOrigin = origin(of: downloadURL) {
            receipt.downloadOrigin = describe(downloadOrigin)
        }
        guard let raw = manifest.complete?.url, let completeURL = URL(string: raw) else {
            receipt.callbackAllowed = false
            receipt.callbackURL = ""
            receipt.allowedCallbackOrigin = ""
            receipt.callbackState = "missing"
            return
        }
        guard let pinned = pinnedCallbackURL(complete: completeURL, download: downloadURL, finalDownload: finalDownloadURL),
              let pinnedOrigin = origin(of: pinned) else {
            receipt.callbackAllowed = false
            receipt.callbackURL = ""
            receipt.allowedCallbackOrigin = ""
            receipt.callbackState = "origin_mismatch"
            return
        }
        receipt.callbackAllowed = true
        receipt.callbackURL = pinned.absoluteString
        receipt.allowedCallbackOrigin = describe(pinnedOrigin)
        receipt.callbackState = "allowed"
    }

    static func basicAuthorization(
        enabled: Bool,
        username: String,
        password: String,
        endpoint: String,
        callback: URL
    ) -> String? {
        guard enabled, !username.isEmpty, !password.isEmpty else { return nil }
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpointURL = URL(string: trimmed),
              let endpointOrigin = origin(of: endpointURL),
              let callbackOrigin = origin(of: callback),
              endpointOrigin == callbackOrigin,
              let data = "\(username):\(password)".data(using: .utf8) else { return nil }
        return "Basic \(data.base64EncodedString())"
    }

    static func makeRequest(url: URL, savedIDs: [String], failedIDs: [String], authorization: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        let body: [String: [String]] = ["failed_ids": failedIDs, "saved_ids": savedIDs]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    static func parseConfirmation(status: Int, body: Data) -> Result<Confirmation, ParseFailure> {
        guard (200..<300).contains(status) else {
            return .failure(ParseFailure(outcome: .httpError, detail: httpDetail(status: status, body: body)))
        }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return .failure(ParseFailure(outcome: .invalidResponse, detail: "The WebUI response was not a JSON object."))
        }
        guard let rawIDs = object["saved_ids"] as? [Any] else {
            return .failure(ParseFailure(outcome: .invalidResponse, detail: "The WebUI response did not include saved_ids."))
        }
        let savedIDs = rawIDs.compactMap { $0 as? String }
        if savedIDs.count != rawIDs.count {
            return .failure(ParseFailure(outcome: .invalidResponse, detail: "The WebUI response included a saved_ids entry that was not text."))
        }
        var rejected: [ObsidianRejectedNote] = []
        if let rawRejected = object["rejected"] as? [Any] {
            for item in rawRejected {
                guard let entry = item as? [String: Any], let id = entry["id"] as? String else { continue }
                let reason = (entry["reason"] as? String) ?? "rejected"
                rejected.append(ObsidianRejectedNote(id: id, reason: reason))
            }
        }
        return .success(Confirmation(savedIDs: savedIDs, rejected: rejected))
    }

    static func diagnostic(
        exportID: String,
        written: Int,
        failed: Int,
        confirmed: Int,
        callbackOrigin: String,
        configuredBackendOrigin: String,
        authAttached: Bool,
        httpStatus: Int?,
        result: String,
        detail: String,
        secrets: [String]
    ) -> String {
        var object: [String: Any] = [
            "auth_attached": authAttached,
            "callback_origin": callbackOrigin,
            "configured_backend_origin": configuredBackendOrigin,
            "detail": redactSecrets(detail, extraSecrets: secrets),
            "export_id": safeExportID(exportID),
            "local_write_failures": failed,
            "notes_written": written,
            "phase": "acknowledge",
            "result": result,
            "webui_confirmed": confirmed
        ]
        if let httpStatus {
            object["http_status"] = httpStatus
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              var text = String(data: data, encoding: .utf8) else {
            return "{\"phase\":\"acknowledge\",\"result\":\"\(result)\"}"
        }
        text = redactSecrets(text, extraSecrets: secrets)
        return text
    }

    private static func httpDetail(status: Int, body: Data) -> String {
        let snippet = bodySnippet(body)
        switch status {
        case 401:
            return "The WebUI returned HTTP 401 for the completion callback. \(snippet)"
        case 404:
            return "The WebUI returned HTTP 404. This export was not found on the WebUI that served it. \(snippet)"
        case 500...599:
            return "The WebUI returned HTTP \(status) while confirming the save. \(snippet)"
        default:
            return "The WebUI returned HTTP \(status) for the completion callback. \(snippet)"
        }
    }

    private static func bodySnippet(_ body: Data) -> String {
        guard let text = String(data: body, encoding: .utf8) else { return "" }
        let flattened = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if flattened.isEmpty { return "" }
        let clipped = flattened.count > 180 ? String(flattened.prefix(180)) : flattened
        if let data = clipped.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = object["detail"] as? String {
            return detail
        }
        return clipped
    }
}

#if os(macOS)
final class ObsidianRedirectStopper: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct URLSessionObsidianCompletionSender {
    static let shared = URLSessionObsidianCompletionSender()

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: ObsidianRedirectStopper(), delegateQueue: nil)
    }

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }
}
#endif
