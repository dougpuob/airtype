import CryptoKit
import Foundation

enum LocalASRDownloadError: LocalizedError {
    case busy
    case overridden(String)
    case hashMismatch(String)
    case extractFailed
    case incomplete

    var errorDescription: String? {
        switch self {
        case .busy: return "Another model is already downloading."
        case .overridden(let key): return "\(key) is set, so this pane will not download over that directory."
        case .hashMismatch(let name): return "SHA-256 mismatch for \(name)."
        case .extractFailed: return "Could not extract the archive."
        case .incomplete: return "Download finished but model files are missing."
        }
    }
}

/// Downloads one local ASR model at a time into `~/.airtype/models/asr`.
/// Archives come from the sherpa-onnx release; Qwen3-ASR 1.7B is fetched file-by-file and hashed.
@MainActor
final class LocalASRDownloader {
    static let shared = LocalASRDownloader()

    private(set) var activeKind: ASREngineKind?
    /// Status line for `activeKind` ("Downloading 42%", "Extracting…", "Verifying…").
    private(set) var statusText = ""
    private var failures: [ASREngineKind: String] = [:]
    private var task: Task<Void, Never>?
    private var transfer: LocalASRTransfer?
    var onChange: (() -> Void)?

    func failure(for kind: ASREngineKind) -> String? { failures[kind] }

    func download(_ model: LocalASRModel) {
        guard activeKind == nil else { return }
        guard !model.isOverridden else { return }
        failures[model.kind] = nil
        activeKind = model.kind
        statusText = "Downloading…"
        publish()
        let transfer = LocalASRTransfer()
        self.transfer = transfer
        task = Task { [weak self] in
            do {
                try await Self.install(model, transfer: transfer) { text in
                    Task { @MainActor in self?.setStatus(text) }
                }
                await MainActor.run { self?.finishSuccess(model.kind) }
            } catch is CancellationError {
                await MainActor.run { self?.finishCancel() }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { self?.finishFailure(model.kind, message) }
            }
        }
    }

    func cancel() {
        task?.cancel()
        transfer?.cancel()
    }

    /// Deletes the default install directory. Does not remove the shared Silero VAD or an env override.
    func remove(_ model: LocalASRModel) throws {
        guard activeKind != model.kind else { return }
        guard !model.isOverridden else { return }
        let directory = model.installDirectory
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        failures[model.kind] = nil
        Logger.shared.log("Local ASR removed \(model.kind.rawValue) at \(directory.path)")
        publish()
    }

    private func setStatus(_ text: String) {
        guard activeKind != nil else { return }
        statusText = text
        publish()
    }

    private func finishSuccess(_ kind: ASREngineKind) {
        Logger.shared.log("Local ASR downloaded \(kind.rawValue)")
        failures[kind] = nil
        clearActive()
    }

    private func finishCancel() {
        if let kind = activeKind {
            Logger.shared.log("Local ASR download cancelled \(kind.rawValue)")
        }
        clearActive()
    }

    private func finishFailure(_ kind: ASREngineKind, _ message: String) {
        Logger.shared.log("Local ASR download failed \(kind.rawValue): \(message)")
        failures[kind] = message
        clearActive()
    }

    private func clearActive() {
        activeKind = nil
        statusText = ""
        task = nil
        transfer = nil
        publish()
    }

    private func publish() {
        onChange?()
    }

    /// Off the main actor. `status` may be called from a background queue.
    nonisolated private static func install(
        _ model: LocalASRModel,
        transfer: LocalASRTransfer,
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        try Task.checkCancellation()
        switch model.source {
        case .archive(let url):
            if !model.containsModelFiles(at: model.installDirectory) {
                status("Downloading…")
                let archive = model.installDirectory
                    .deletingLastPathComponent()
                    .appendingPathComponent(model.directoryName + ".tar.bz2")
                let part = archive.appendingPathExtension("part")
                do {
                    let temp = try await transfer.download(url) { fraction in
                        if let fraction {
                            status("Downloading \(Int((fraction * 100).rounded()))%")
                        } else {
                            status("Downloading…")
                        }
                    }
                    defer { try? FileManager.default.removeItem(at: temp) }
                    try Task.checkCancellation()
                    let fm = FileManager.default
                    try? fm.removeItem(at: part)
                    try fm.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: temp, to: part)
                    status("Extracting…")
                    try await blocking { try extract(archive: part, into: AirTypeHome.asrModels) }
                    try? fm.removeItem(at: part)
                } catch {
                    try? FileManager.default.removeItem(at: part)
                    if !model.containsModelFiles(at: model.installDirectory) {
                        try? FileManager.default.removeItem(at: model.installDirectory)
                    }
                    throw error
                }
            }
        case .files(let base, let items):
            let total = items.count
            for (index, file) in items.enumerated() {
                try Task.checkCancellation()
                let destination = model.installDirectory.appendingRelativePath(file.relativePath)
                if await fileMatchesHash(destination, expected: file.sha256) {
                    status("Downloading \(Int((Double(index + 1) / Double(total) * 100).rounded()))%")
                    continue
                }
                guard let remote = URL(string: file.remotePath, relativeTo: base)?.absoluteURL else {
                    throw LocalASRDownloadError.incomplete
                }
                status("Downloading \(file.relativePath)…")
                let part = destination.appendingPathExtension("part")
                do {
                    let temp = try await transfer.download(remote) { fraction in
                        let overall = (Double(index) + (fraction ?? 0)) / Double(total)
                        status("Downloading \(Int((overall * 100).rounded()))%")
                    }
                    defer { try? FileManager.default.removeItem(at: temp) }
                    try Task.checkCancellation()
                    status("Verifying \(file.relativePath)…")
                    let got = try await blocking { try sha256Hex(of: temp) }
                    guard got == file.sha256 else {
                        try? FileManager.default.removeItem(at: temp)
                        throw LocalASRDownloadError.hashMismatch(file.relativePath)
                    }
                    let fm = FileManager.default
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.removeItem(at: part)
                    try? fm.removeItem(at: destination)
                    try fm.moveItem(at: temp, to: destination)
                } catch {
                    try? FileManager.default.removeItem(at: part)
                    throw error
                }
            }
        }
        try Task.checkCancellation()
        if model.needsVAD, !FileManager.default.fileExists(atPath: LocalASRCatalog.vadURL.path) {
            status("Downloading VAD…")
            let part = LocalASRCatalog.vadURL.appendingPathExtension("part")
            do {
                let temp = try await transfer.download(LocalASRCatalog.vadDownloadURL) { _ in
                    status("Downloading VAD…")
                }
                defer { try? FileManager.default.removeItem(at: temp) }
                let fm = FileManager.default
                try fm.createDirectory(at: LocalASRCatalog.vadURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: part)
                try fm.moveItem(at: temp, to: LocalASRCatalog.vadURL)
            } catch {
                try? FileManager.default.removeItem(at: part)
                throw error
            }
        }
        let installed = model.containsModelFiles(at: model.installDirectory)
            && (!model.needsVAD || FileManager.default.fileExists(atPath: LocalASRCatalog.vadURL.path))
        guard installed else {
            if case .archive = model.source, !model.containsModelFiles(at: model.installDirectory) {
                try? FileManager.default.removeItem(at: model.installDirectory)
            }
            throw LocalASRDownloadError.incomplete
        }
    }

    nonisolated private static func fileMatchesHash(_ url: URL, expected: String) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let got = try? await blocking({ try sha256Hex(of: url) }) else { return false }
        return got == expected
    }

    nonisolated private static func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    nonisolated private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func extract(archive: URL, into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "-C", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LocalASRDownloadError.extractFailed }
    }
}

/// One URLSession download at a time. The temp file is moved out of the session's temp dir
/// before the delegate returns, so the caller can hash or extract it.
final class LocalASRTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession!
    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: ((Double?) -> Void)?
    private var cancelled = false

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func download(_ url: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            self.progressHandler = progress
            lock.unlock()
            session.downloadTask(with: url).resume()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        session.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fraction: Double? = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : nil
        lock.lock()
        let handler = progressHandler
        lock.unlock()
        handler?(fraction)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("airtype-asr-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            resume(returning: destination)
        } catch {
            resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            resume(throwing: error)
        }
    }

    private func resume(returning url: URL) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled {
            try? FileManager.default.removeItem(at: url)
            continuation?.resume(throwing: CancellationError())
        } else {
            continuation?.resume(returning: url)
        }
    }

    private func resume(throwing error: Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled || (error as? URLError)?.code == .cancelled {
            continuation?.resume(throwing: CancellationError())
        } else {
            continuation?.resume(throwing: error)
        }
    }
}
