import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class CheckLog: @unchecked Sendable {
    private var failedCount = 0
    var failed: Int { failedCount }

    func check(_ condition: Bool, _ message: String) {
        if condition { return }
        failedCount += 1
        fputs("FAIL \(message)\n", stderr)
    }
}

@main
struct ObsidianImportCompletionTestMain {
    static func main() async {
        let log = CheckLog()
        let check = log.check

        check(SHA256Hex.hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "sha256 empty")
        check(SHA256Hex.hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 abc")

        let redacted = ObsidianCompletion.redactSecrets("POST /complete?token=super-secret-token HTTP Authorization: Basic dXNlcjpwYXNz")
        check(!redacted.contains("super-secret-token"), "redact query token")
        check(redacted.contains("token=[redacted]"), "redact token marker")
        check(!redacted.contains("dXNlcjpwYXNz"), "redact basic")
        check(ObsidianCompletion.redactSecrets("max_tokens=32") == "max_tokens=32", "keep max_tokens")

        await testSuccessfulBatch(check)
        await testPartialLocalFailure(check)
        await testHTTPStatus(check, status: 401)
        await testHTTPStatus(check, status: 404)
        await testHTTPStatus(check, status: 500)
        await testTransportAndRetry(check)
        await testInvalidResponse(check)
        await testDuplicateImportDoesNotRewrite(check)
        await testOriginAndAuth(check)
        await testSchemePin(check)
        testPlaceReusesIdenticalFile(check)
        testReceiptPermissions(check)

        if log.failed != 0 {
            fputs("\(log.failed) failed\n", stderr)
            exit(1)
        }
        print("ok")
    }

    static func testSuccessfulBatch(_ check: (Bool, String) -> Void) async {
        let harness = Harness()
        let manifest = sampleManifest(completeHost: "http://127.0.0.1:8003")
        harness.script = [.success((200, okBody(["a", "b"])))]
        let report = await harness.engine().importManifest(
            manifest: manifest,
            downloadURL: downloadURL("http://127.0.0.1:8003"),
            finalDownloadURL: downloadURL("http://127.0.0.1:8003"),
            configuredEndpoint: "https://airtype.example",
            authEnabled: true,
            username: "airtype",
            password: "s3cret-password"
        )
        check(harness.writes == 2, "success writes \(harness.writes)")
        check(harness.sends == 1, "success sends")
        check(report.outcome == .confirmed, "success outcome \(report.outcome)")
        check(report.confirmedIDs == ["a", "b"], "success confirmed \(report.confirmedIDs)")
        check(report.canRetryAcknowledgement == false, "success no retry")
        check(report.authAttached == false, "success does not attach auth to a different origin")
        check(report.callbackOrigin == "http://127.0.0.1:8003", "callback origin \(report.callbackOrigin)")
        let request = harness.requests[0]
        check(request.httpMethod == "POST", "method")
        check(request.value(forHTTPHeaderField: "Authorization") == nil, "no authorization header")
        check(request.url?.host == "127.0.0.1", "callback host")
        check(request.url?.path.hasSuffix("/complete") == true, "callback path \(request.url?.path ?? "")")
        let body = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        check((body?["saved_ids"] as? [String]) == ["a", "b"], "saved body \(String(describing: body))")
        check((body?["failed_ids"] as? [String]) == [], "failed body")
        let dialog = ObsidianImportDialog.make(report)
        check(dialog.title == "Imported to Obsidian", "dialog title \(dialog.title)")
        check(dialog.message.contains("Notes written: 2"), "dialog written")
        check(dialog.message.contains("WebUI confirmed: 2"), "dialog confirmed")
        check(!dialog.message.contains("test-token-value"), "dialog token")
        check(!dialog.message.contains("s3cret-password"), "dialog password")
        check(!report.diagnosticText.contains("test-token-value"), "diagnostic token")
        check(!report.historySourceURL.contains("token="), "history url \(report.historySourceURL)")
        check(report.historySourceURL.contains("/api/obsidian-exports/exp1"), "history path")
    }

    static func testPartialLocalFailure(_ check: (Bool, String) -> Void) async {
        let harness = Harness()
        harness.failTitles = ["Broken"]
        var manifest = sampleManifest(completeHost: "http://127.0.0.1:8003")
        manifest.notes[1].title = "Broken"
        harness.script = [.success((200, okBody(["a"])))]
        let report = await harness.engine().importManifest(
            manifest: manifest,
            downloadURL: downloadURL("http://127.0.0.1:8003"),
            finalDownloadURL: downloadURL("http://127.0.0.1:8003"),
            configuredEndpoint: "http://127.0.0.1:8003",
            authEnabled: false,
            username: "",
            password: ""
        )
        check(report.outcome == .confirmed, "partial local outcome \(report.outcome)")
        check(report.writtenIDs == ["a"], "partial written")
        check(report.writeFailures.map(\.id) == ["b"], "partial failed id")
        check(report.confirmedIDs == ["a"], "partial confirmed")
        let body = try? JSONSerialization.jsonObject(with: harness.requests[0].httpBody ?? Data()) as? [String: Any]
        check((body?["saved_ids"] as? [String]) == ["a"], "partial saved body")
        check((body?["failed_ids"] as? [String]) == ["b"], "partial failed body")
        let dialog = ObsidianImportDialog.make(report)
        check(dialog.message.contains("Notes written: 1"), "partial dialog written")
        check(dialog.message.contains("WebUI confirmed: 1"), "partial dialog confirmed")
        check(dialog.message.contains("Local write failures: 1"), "partial dialog failures")
        check(!dialog.offerRetry, "partial local ack does not need retry")
    }

    static func testHTTPStatus(_ check: (Bool, String) -> Void, status: Int) async {
        let harness = Harness()
        let body = Data("{\"detail\":\"Authentication required token=test-token-value\"}".utf8)
        harness.script = [.success((status, body))]
        let report = await harness.engine().importManifest(
            manifest: sampleManifest(completeHost: "https://files.example"),
            downloadURL: downloadURL("https://files.example"),
            finalDownloadURL: downloadURL("https://files.example"),
            configuredEndpoint: "http://127.0.0.1:8003",
            authEnabled: true,
            username: "airtype",
            password: "s3cret-password"
        )
        check(report.outcome == .httpError, "http \(status) outcome \(report.outcome)")
        check(report.httpStatus == status, "http \(status) status field")
        check(report.confirmedIDs.isEmpty, "http \(status) confirmed empty")
        check(report.writtenIDs == ["a", "b"], "http \(status) notes stay written")
        check(report.canRetryAcknowledgement, "http \(status) can retry")
        check(report.diagnosticText.contains("\"http_status\":\(status)"), "http \(status) diagnostic")
        check(!report.diagnosticText.contains("test-token-value"), "http \(status) diagnostic token")
        check(!ObsidianImportDialog.make(report).message.contains("test-token-value"), "http \(status) dialog token")
        check(report.authAttached == false, "http \(status) auth stays off the other host")
    }

    static func testTransportAndRetry(_ check: (Bool, String) -> Void) async {
        let harness = Harness()
        harness.script = [
            .failure(URLError(.cannotConnectToHost)),
            .success((200, okBody(["a", "b"])))
        ]
        let engine = harness.engine()
        let first = await engine.importManifest(
            manifest: sampleManifest(completeHost: "https://files.example"),
            downloadURL: downloadURL("https://files.example"),
            finalDownloadURL: downloadURL("https://files.example"),
            configuredEndpoint: "http://127.0.0.1:8003",
            authEnabled: false,
            username: "",
            password: ""
        )
        check(first.outcome == .transport, "transport outcome \(first.outcome)")
        check(first.canRetryAcknowledgement, "transport can retry")
        check(harness.writes == 2, "transport wrote notes")
        check(first.confirmedIDs.isEmpty, "transport confirmed none")
        let dialog = ObsidianImportDialog.make(first)
        check(dialog.title == "Notes written, WebUI not confirmed", "transport title \(dialog.title)")
        check(dialog.offerRetry, "transport offers retry")
        check(dialog.message.contains("Notes written: 2"), "transport written line")
        check(dialog.message.contains("WebUI confirmed: 0"), "transport confirmed line")
        let second = await engine.retryAcknowledgement(
            exportID: first.exportID,
            configuredEndpoint: "http://127.0.0.1:8003",
            authEnabled: false,
            username: "",
            password: ""
        )
        check(harness.writes == 2, "retry did not write again \(harness.writes)")
        check(harness.sends == 2, "retry sent again")
        check(second.outcome == .confirmed, "retry confirmed \(second.outcome)")
        check(second.confirmedIDs == ["a", "b"], "retry ids")
        check(!second.canRetryAcknowledgement, "retry finished")
    }

    static func testInvalidResponse(_ check: (Bool, String) -> Void) async {
        let harness = Harness()
        harness.script = [.success((200, Data("{\"ok\":true}".utf8)))]
        let missing = await harness.engine().importManifest(
            manifest: sampleManifest(completeHost: "https://files.example"),
            downloadURL: downloadURL("https://files.example"),
            finalDownloadURL: downloadURL("https://files.example"),
            configuredEndpoint: "",
            authEnabled: false,
            username: "",
            password: ""
        )
        check(missing.outcome == .invalidResponse, "missing saved_ids \(missing.outcome)")
        check(missing.canRetryAcknowledgement, "invalid can retry")
        check(!missing.diagnosticText.contains("test-token-value"), "invalid diagnostic token")

        let harness2 = Harness()
        harness2.script = [.success((200, Data("{\"saved_ids\":[\"a\"],\"rejected\":[{\"id\":\"b\",\"reason\":\"changed\"}]}".utf8)))]
        let partial = await harness2.engine().importManifest(
            manifest: sampleManifest(completeHost: "https://files.example"),
            downloadURL: downloadURL("https://files.example"),
            finalDownloadURL: downloadURL("https://files.example"),
            configuredEndpoint: "",
            authEnabled: false,
            username: "",
            password: ""
        )
        check(partial.outcome == .partial, "partial outcome \(partial.outcome)")
        check(partial.confirmedIDs == ["a"], "partial confirmed only a")
        check(partial.rejected.map(\.reason) == ["changed"], "partial reason")
        check(partial.canRetryAcknowledgement, "partial can retry")
        let before = harness2.writes
        harness2.script.append(.success((200, Data("{\"saved_ids\":[\"a\"],\"rejected\":[{\"id\":\"b\",\"reason\":\"changed\"}]}".utf8))))
        _ = await harness2.engine().retryAcknowledgement(
            exportID: partial.exportID,
            configuredEndpoint: "",
            authEnabled: false,
            username: "",
            password: ""
        )
        check(harness2.writes == before, "partial retry does not rewrite")
        check(ObsidianImportDialog.make(partial).message.contains("the note changed after this export was created"), "partial dialog reason")
    }

    static func testDuplicateImportDoesNotRewrite(_ check: (Bool, String) -> Void) async {
        let harness = Harness()
        harness.script = [
            .success((500, Data("{\"detail\":\"busy\"}".utf8))),
            .success((200, okBody(["a", "b"])))
        ]
        let engine = harness.engine()
        let manifest = sampleManifest(completeHost: "https://files.example")
        let download = downloadURL("https://files.example")
        let first = await engine.importManifest(
            manifest: manifest,
            downloadURL: download,
            finalDownloadURL: download,
            configuredEndpoint: "http://127.0.0.1:8003",
            authEnabled: false,
            username: "",
            password: ""
        )
        check(first.outcome == .httpError, "duplicate setup outcome")
        let second = await engine.importManifest(
            manifest: manifest,
            downloadURL: download,
            finalDownloadURL: download,
            configuredEndpoint: "http://127.0.0.1:8003",
            authEnabled: false,
            username: "",
            password: ""
        )
        check(harness.writes == 2, "second import reused written notes \(harness.writes)")
        check(second.outcome == .confirmed, "second import confirmed \(second.outcome)")
        check(second.confirmedIDs == ["a", "b"], "second import ids")
    }

    static func testOriginAndAuth(_ check: (Bool, String) -> Void) async {
        let evil = Harness()
        var manifest = sampleManifest(completeHost: "https://files.example")
        manifest.complete = .init(method: "POST", url: "https://evil.example/steal?token=test-token-value")
        let refused = await evil.engine().importManifest(
            manifest: manifest,
            downloadURL: downloadURL("https://files.example"),
            finalDownloadURL: downloadURL("https://files.example"),
            configuredEndpoint: "https://files.example",
            authEnabled: true,
            username: "airtype",
            password: "s3cret-password"
        )
        check(evil.sends == 0, "evil host was not called")
        check(evil.writes == 2, "notes still written when callback host is refused")
        check(refused.outcome == .originMismatch, "origin outcome \(refused.outcome)")
        check(!refused.canRetryAcknowledgement, "origin mismatch is not a blind retry")
        check(refused.authAttached == false, "auth not attached on mismatch")
        check(!refused.diagnosticText.contains("test-token-value"), "mismatch diagnostic token")
        check(!refused.diagnosticText.contains("s3cret-password"), "mismatch diagnostic password")
        check(!ObsidianImportDialog.make(refused).message.contains("test-token-value"), "mismatch dialog token")
        let again = await evil.engine().importManifest(
            manifest: manifest,
            downloadURL: downloadURL("https://files.example"),
            finalDownloadURL: downloadURL("https://files.example"),
            configuredEndpoint: "https://files.example",
            authEnabled: true,
            username: "airtype",
            password: "s3cret-password"
        )
        check(evil.writes == 2, "refused import does not rewrite \(evil.writes)")
        check(again.outcome == .originMismatch, "second refusal")

        let matched = Harness()
        matched.script = [.success((200, okBody(["a", "b"])))]
        let report = await matched.engine().importManifest(
            manifest: sampleManifest(completeHost: "http://127.0.0.1:8003"),
            downloadURL: downloadURL("http://127.0.0.1:8003"),
            finalDownloadURL: downloadURL("http://127.0.0.1:8003"),
            configuredEndpoint: "http://127.0.0.1:8003",
            authEnabled: true,
            username: "airtype",
            password: "s3cret-password"
        )
        let header = matched.requests[0].value(forHTTPHeaderField: "Authorization") ?? ""
        check(header.hasPrefix("Basic "), "matching origin attaches basic auth")
        let encoded = String(header.dropFirst("Basic ".count))
        let decoded = encoded.isEmpty ? nil : Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) }
        check(decoded == "airtype:s3cret-password", "basic payload")
        check(report.authAttached, "auth flag")
        let dialog = ObsidianImportDialog.make(report)
        check(!dialog.message.contains("s3cret-password"), "auth dialog password")
        check(!dialog.message.contains(encoded), "auth dialog header")
        check(!report.diagnosticText.contains(encoded), "auth diagnostic header")

        let otherPort = Harness()
        otherPort.script = [.success((200, okBody(["a", "b"])))]
        let portReport = await otherPort.engine().importManifest(
            manifest: sampleManifest(completeHost: "http://127.0.0.1:8004"),
            downloadURL: downloadURL("http://127.0.0.1:8004"),
            finalDownloadURL: downloadURL("http://127.0.0.1:8004"),
            configuredEndpoint: "http://127.0.0.1:8003",
            authEnabled: true,
            username: "airtype",
            password: "s3cret-password"
        )
        check(otherPort.requests[0].url?.port == 8004, "callback keeps its port")
        check(otherPort.requests[0].value(forHTTPHeaderField: "Authorization") == nil, "different port gets no basic auth")
        check(portReport.authAttached == false, "port auth flag")
        check(portReport.configuredBackendOrigin.contains("8003"), "diagnostic shows configured backend \(portReport.configuredBackendOrigin)")
        check(portReport.callbackOrigin.contains("8004"), "diagnostic shows callback origin \(portReport.callbackOrigin)")
    }

    static func testSchemePin(_ check: (Bool, String) -> Void) async {
        let harness = Harness()
        harness.script = [.success((200, okBody(["a", "b"])))]
        let download = URL(string: "http://files.example/api/obsidian-exports/exp1?token=test-token-value")!
        let final = URL(string: "https://files.example/api/obsidian-exports/exp1?token=test-token-value")!
        var manifest = sampleManifest(completeHost: "http://files.example")
        manifest.complete = .init(method: "POST", url: "http://files.example/api/obsidian-exports/exp1/complete?token=test-token-value")
        _ = await harness.engine().importManifest(
            manifest: manifest,
            downloadURL: download,
            finalDownloadURL: final,
            configuredEndpoint: "http://127.0.0.1:8003",
            authEnabled: true,
            username: "airtype",
            password: "s3cret-password"
        )
        let url = harness.requests[0].url
        check(url?.scheme == "https", "pinned scheme \(url?.scheme ?? "")")
        check(url?.host == "files.example", "pinned host")
        check(url?.path == "/api/obsidian-exports/exp1/complete", "pinned path \(url?.path ?? "")")
        check(url?.query?.contains("token=test-token-value") == true, "pinned query keeps token")
        check(harness.requests[0].value(forHTTPHeaderField: "Authorization") == nil, "pinned https host gets no localhost credentials")
    }

    static func testPlaceReusesIdenticalFile(_ check: (Bool, String) -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("airtype-place-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try! ObsidianNoteFiles.place(markdown: "# Hello\n", title: "Hello", directory: directory, reuseIdentical: true)
        let second = try! ObsidianNoteFiles.place(markdown: "# Hello\n", title: "Hello", directory: directory, reuseIdentical: true)
        check(first.path == second.path, "identical note is not duplicated")
        check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Hello 2.md").path), "no numbered duplicate")
        let different = try! ObsidianNoteFiles.place(markdown: "# Edited\n", title: "Hello", directory: directory, reuseIdentical: true)
        check(different.lastPathComponent == "Hello 2.md", "different contents keep the existing file \(different.lastPathComponent)")
        let forced = try! ObsidianNoteFiles.place(markdown: "# Edited\n", title: "Hello", directory: directory, reuseIdentical: false)
        check(forced.lastPathComponent == "Hello 3.md", "reuse disabled still numbers collisions")
    }

    static func testReceiptPermissions(_ check: (Bool, String) -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("airtype-receipt-\(UUID().uuidString)", isDirectory: true)
        let store = ObsidianImportReceiptStore(directory: directory)
        let receipt = ObsidianImportReceipt(
            exportID: "exp1",
            downloadOrigin: "https://files.example:443",
            allowedCallbackOrigin: "https://files.example:443",
            historySourceURL: "https://files.example/api/obsidian-exports/exp1",
            callbackURL: "https://files.example/api/obsidian-exports/exp1/complete?token=test-token-value",
            callbackAllowed: true,
            callbackState: "allowed",
            notes: []
        )
        try! store.save(receipt)
        let path = store.fileURL("exp1").path
        let text = try! String(contentsOfFile: path, encoding: .utf8)
        check(text.contains("test-token-value"), "receipt keeps the callback token for retry")
        let mode = posixMode(path)
        check(mode == 0o600, "receipt mode \(String(mode, radix: 8))")
        let directoryMode = posixMode(directory.path)
        check(directoryMode == 0o700, "receipt directory mode \(String(directoryMode, radix: 8))")
    }

    static func sampleManifest(completeHost: String) -> ObsidianImportManifest {
        let base = completeHost.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return ObsidianImportManifest(
            schemaVersion: 1,
            kind: "airtype.obsidian_import",
            exportID: "exp1",
            exportedAt: nil,
            source: nil,
            vaultFolder: "Inbox",
            notes: [
                ObsidianImportManifest.Note(id: "a", title: "One", markdown: "# One\n", createdAt: nil, tags: nil, folder: nil, sourceURL: nil, markSaved: nil),
                ObsidianImportManifest.Note(id: "b", title: "Two", markdown: "# Two\n", createdAt: nil, tags: nil, folder: "Nested", sourceURL: nil, markSaved: nil)
            ],
            complete: .init(method: "POST", url: "\(base)/api/obsidian-exports/exp1/complete?token=test-token-value")
        )
    }

    static func downloadURL(_ host: String) -> URL {
        let base = host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/api/obsidian-exports/exp1?token=test-token-value")!
    }

    static func okBody(_ ids: [String]) -> Data {
        let object: [String: Any] = ["ok": true, "saved_ids": ids, "failed_ids": [], "rejected": []]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func posixMode(_ path: String) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return -1 }
        if let value = attrs[.posixPermissions] as? Int { return value & 0o777 }
        if let value = attrs[.posixPermissions] as? NSNumber { return value.intValue & 0o777 }
        return -1
    }
}

final class Harness {
    var writes = 0
    var sends = 0
    var requests: [URLRequest] = []
    var files: [String: Data] = [:]
    var failTitles: Set<String> = []
    var script: [Result<(status: Int, body: Data), Error>] = []
    let store: ObsidianImportReceiptStore
    let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("airtype-import-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ObsidianImportReceiptStore(directory: directory.appendingPathComponent("receipts", isDirectory: true))
    }

    func engine() -> ObsidianImportEngine {
        ObsidianImportEngine(
            receipts: store,
            send: { request in
                self.sends += 1
                self.requests.append(request)
                let next = self.script.removeFirst()
                switch next {
                case .success(let response):
                    return response
                case .failure(let error):
                    throw error
                }
            },
            writeNote: { title, markdown, _ in
                self.writes += 1
                if self.failTitles.contains(title) {
                    throw ObsidianNoteFileError.writeFailed("disk full")
                }
                let url = self.directory.appendingPathComponent("\(title).md")
                let data = Data(markdown.utf8)
                self.files[url.path] = data
                return url
            },
            readFile: { path in
                self.files[path]
            }
        )
    }
}
