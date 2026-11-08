import CSherpaOnnx
import Foundation

/// Local streaming ASR: sherpa-onnx online Paraformer bilingual (zh + en, int8).
///
/// Same feed/decode loop as Nemotron. On stop we set stream option `is_final=1` (required by
/// streaming Paraformer) then pad silence and finish the stream.
final class ParaformerStreamingEngine: ASREngine, @unchecked Sendable {
    typealias State = ASREngineState
    let kind: ASREngineKind = .paraformer

    static let defaultModelName = "sherpa-onnx-streaming-paraformer-bilingual-zh-en"

    static var modelDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AIRTYPE_PARAFORMER_MODEL_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".airtype/models/asr")
            .appendingPathComponent(defaultModelName)
    }

    private let queue = DispatchQueue(label: "airtype.paraformer.engine", qos: .userInitiated)
    private let sampleRate: Int32 = 16_000
    private var recognizer: OpaquePointer?
    private var stream: OpaquePointer?
    private var sessionID = 0
    private var lastText = ""
    private var onUpdate: ((String) -> Void)?
    private var fedSamples = 0
    private var decodeSeconds = 0.0

    private let stateLock = NSLock()
    private var _state: State = .notLoaded
    var state: State {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }
    private func setState(_ value: State) {
        stateLock.lock(); _state = value; stateLock.unlock()
    }

    deinit {
        if let stream { SherpaOnnxDestroyOnlineStream(stream) }
        if let recognizer { SherpaOnnxDestroyOnlineRecognizer(recognizer) }
    }

    func load(completion: @escaping (State) -> Void) {
        queue.async { [self] in
            if recognizer != nil {
                completion(.ready)
                return
            }
            setState(.loading)
            let dir = Self.modelDirectory
            let files = ["encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt"]
            for file in files where !FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path) {
                let message = "Paraformer model file missing: \(dir.appendingPathComponent(file).path) (run scripts/setup-paraformer.sh)"
                Logger.shared.log(message)
                setState(.failed(message))
                completion(.failed(message))
                return
            }

            let startedAt = Date()
            let encoder = strdup(dir.appendingPathComponent("encoder.int8.onnx").path)
            let decoder = strdup(dir.appendingPathComponent("decoder.int8.onnx").path)
            let tokens = strdup(dir.appendingPathComponent("tokens.txt").path)
            let provider = strdup("cpu")
            let decoding = strdup("greedy_search")
            defer {
                free(encoder); free(decoder); free(tokens); free(provider); free(decoding)
            }

            var config = SherpaOnnxOnlineRecognizerConfig()
            memset(&config, 0, MemoryLayout<SherpaOnnxOnlineRecognizerConfig>.size)
            config.feat_config.sample_rate = sampleRate
            config.feat_config.feature_dim = 80
            config.model_config.paraformer.encoder = UnsafePointer(encoder)
            config.model_config.paraformer.decoder = UnsafePointer(decoder)
            config.model_config.tokens = UnsafePointer(tokens)
            config.model_config.num_threads = 4
            config.model_config.provider = UnsafePointer(provider)
            config.decoding_method = UnsafePointer(decoding)
            // Finalize on hotkey stop via is_final + InputFinished (not endpoint rules).
            config.enable_endpoint = 0

            guard let created = SherpaOnnxCreateOnlineRecognizer(&config) else {
                let message = "SherpaOnnxCreateOnlineRecognizer failed for Paraformer (model dir: \(dir.path))"
                Logger.shared.log(message)
                setState(.failed(message))
                completion(.failed(message))
                return
            }
            recognizer = created
            setState(.ready)
            Logger.shared.log(
                "Paraformer recognizer ready: model_dir=\(dir.path), load_ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
            )
            completion(.ready)
        }
    }

    func startSession(language: String, onUpdate: @escaping (String) -> Void) {
        queue.async { [self] in
            guard let recognizer else {
                Logger.shared.log("Paraformer session not started: recognizer not loaded")
                return
            }
            if let stream {
                SherpaOnnxDestroyOnlineStream(stream)
                self.stream = nil
            }
            guard let created = SherpaOnnxCreateOnlineStream(recognizer) else {
                Logger.shared.log("SherpaOnnxCreateOnlineStream failed for Paraformer")
                return
            }
            stream = created
            sessionID += 1
            lastText = ""
            fedSamples = 0
            decodeSeconds = 0
            self.onUpdate = onUpdate
            Logger.shared.log("Paraformer session #\(sessionID) started (bilingual zh/en; language hint \(language) unused)")
        }
    }

    func feed(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        queue.async { [self] in
            guard stream != nil else { return }
            let samples = Self.floatSamples(from: pcm)
            accept(samples)
            decodeAndPublish()
        }
    }

    func finish(completion: @escaping (String) -> Void) {
        queue.async { [self] in
            guard let recognizer, let stream else {
                completion(lastText)
                return
            }
            // Streaming Paraformer needs an explicit final chunk.
            SherpaOnnxOnlineStreamSetOption(stream, "is_final", "1")
            accept([Float](repeating: 0, count: Int(Double(sampleRate) * 0.8)))
            SherpaOnnxOnlineStreamInputFinished(stream)
            decodeAndPublish(notify: false)
            let text = currentText(recognizer: recognizer, stream: stream)
            let audioSeconds = Double(fedSamples) / Double(sampleRate)
            Logger.shared.log(
                "Paraformer session #\(sessionID) finished: audio_s=\(String(format: "%.2f", audioSeconds)), "
                + "decode_s=\(String(format: "%.3f", decodeSeconds)), chars=\(text.count)"
            )
            SherpaOnnxDestroyOnlineStream(stream)
            self.stream = nil
            onUpdate = nil
            completion(text)
        }
    }

    func cancel() {
        queue.async { [self] in
            if let stream {
                SherpaOnnxDestroyOnlineStream(stream)
                self.stream = nil
                Logger.shared.log("Paraformer session #\(sessionID) cancelled")
            }
            onUpdate = nil
        }
    }

    // MARK: - Queue-only helpers

    private func accept(_ samples: [Float]) {
        guard let stream, !samples.isEmpty else { return }
        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxOnlineStreamAcceptWaveform(stream, sampleRate, buffer.baseAddress, Int32(buffer.count))
        }
        fedSamples += samples.count
    }

    private func decodeAndPublish(notify: Bool = true) {
        guard let recognizer, let stream else { return }
        let startedAt = Date()
        var decoded = false
        while SherpaOnnxIsOnlineStreamReady(recognizer, stream) == 1 {
            SherpaOnnxDecodeOnlineStream(recognizer, stream)
            decoded = true
        }
        guard decoded else { return }
        decodeSeconds += Date().timeIntervalSince(startedAt)
        let text = currentText(recognizer: recognizer, stream: stream)
        if text != lastText {
            lastText = text
            if notify { onUpdate?(text) }
        }
    }

    private func currentText(recognizer: OpaquePointer, stream: OpaquePointer) -> String {
        guard let result = SherpaOnnxGetOnlineStreamResult(recognizer, stream) else { return lastText }
        defer { SherpaOnnxDestroyOnlineRecognizerResult(result) }
        guard let cText = result.pointee.text else { return "" }
        return String(cString: cText)
    }

    private static func floatSamples(from pcm: Data) -> [Float] {
        let count = pcm.count / MemoryLayout<Int16>.size
        var output = [Float](repeating: 0, count: count)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<count {
                output[index] = Float(samples[index]) / 32768.0
            }
        }
        return output
    }
}
