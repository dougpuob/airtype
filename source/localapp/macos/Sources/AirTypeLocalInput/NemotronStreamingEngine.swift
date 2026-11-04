import CSherpaOnnx
import Foundation

/// Local streaming ASR: sherpa-onnx runtime + NVIDIA Nemotron 3.5 ASR Streaming (0.6B, multilingual, int8).
///
/// All sherpa-onnx calls run on one serial queue. Audio arrives as 16 kHz mono Int16 PCM from
/// `AudioRecorder`, is decoded chunk by chunk (560 ms model chunk), and every time the recognized
/// text grows `onUpdate` is called with the full raw text of the current session.
final class NemotronStreamingEngine: ASREngine, @unchecked Sendable {
    typealias State = ASREngineState
    let kind: ASREngineKind = .nemotron

    static let defaultModelName = "sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-560ms-int8-2026-06-11"

    static var modelDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AIRTYPE_NEMOTRON_MODEL_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".airtype-experiment/models")
            .appendingPathComponent(defaultModelName)
    }

    private let queue = DispatchQueue(label: "airtype.nemotron.engine", qos: .userInitiated)
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

    /// Loads the model in the background (≈0.5 s on M4 Max).
    func load(completion: @escaping (State) -> Void) {
        queue.async { [self] in
            if recognizer != nil {
                completion(.ready)
                return
            }
            setState(.loading)
            let dir = Self.modelDirectory
            let files = ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"]
            for file in files where !FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path) {
                let message = "Nemotron model file missing: \(dir.appendingPathComponent(file).path)"
                Logger.shared.log(message)
                setState(.failed(message))
                completion(.failed(message))
                return
            }

            let startedAt = Date()
            let encoder = strdup(dir.appendingPathComponent("encoder.int8.onnx").path)
            let decoder = strdup(dir.appendingPathComponent("decoder.int8.onnx").path)
            let joiner = strdup(dir.appendingPathComponent("joiner.int8.onnx").path)
            let tokens = strdup(dir.appendingPathComponent("tokens.txt").path)
            let provider = strdup("cpu")
            let decoding = strdup("greedy_search")
            defer {
                free(encoder); free(decoder); free(joiner); free(tokens); free(provider); free(decoding)
            }

            var config = SherpaOnnxOnlineRecognizerConfig()
            memset(&config, 0, MemoryLayout<SherpaOnnxOnlineRecognizerConfig>.size)
            config.feat_config.sample_rate = sampleRate
            config.feat_config.feature_dim = 80
            config.model_config.transducer.encoder = UnsafePointer(encoder)
            config.model_config.transducer.decoder = UnsafePointer(decoder)
            config.model_config.transducer.joiner = UnsafePointer(joiner)
            config.model_config.tokens = UnsafePointer(tokens)
            config.model_config.num_threads = 4
            config.model_config.provider = UnsafePointer(provider)
            config.decoding_method = UnsafePointer(decoding)
            // Cache-aware streaming handles long input; we finalize on hotkey stop instead of endpoints.
            config.enable_endpoint = 0

            guard let created = SherpaOnnxCreateOnlineRecognizer(&config) else {
                let message = "SherpaOnnxCreateOnlineRecognizer failed (model dir: \(dir.path))"
                Logger.shared.log(message)
                setState(.failed(message))
                completion(.failed(message))
                return
            }
            recognizer = created
            setState(.ready)
            Logger.shared.log(
                "Nemotron recognizer ready: model_dir=\(dir.path), load_ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
            )
            completion(.ready)
        }
    }

    /// Starts a new utterance. `language`: "zh", "en", "ja", ... or "auto".
    func startSession(language: String, onUpdate: @escaping (String) -> Void) {
        queue.async { [self] in
            guard let recognizer else {
                Logger.shared.log("Nemotron session not started: recognizer not loaded")
                return
            }
            if let stream {
                SherpaOnnxDestroyOnlineStream(stream)
                self.stream = nil
            }
            guard let created = SherpaOnnxCreateOnlineStream(recognizer) else {
                Logger.shared.log("SherpaOnnxCreateOnlineStream failed")
                return
            }
            SherpaOnnxOnlineStreamSetOption(created, "language", language)
            stream = created
            sessionID += 1
            lastText = ""
            fedSamples = 0
            decodeSeconds = 0
            self.onUpdate = onUpdate
            Logger.shared.log("Nemotron session #\(sessionID) started: language=\(language)")
        }
    }

    /// Feed 16 kHz mono Int16 PCM. Safe to call from the audio thread.
    func feed(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        queue.async { [self] in
            guard stream != nil else { return }
            let samples = Self.floatSamples(from: pcm)
            accept(samples)
            decodeAndPublish()
        }
    }

    /// Flushes the tail of the utterance and returns the final raw text.
    func finish(completion: @escaping (String) -> Void) {
        queue.async { [self] in
            guard let recognizer, let stream else {
                completion(lastText)
                return
            }
            // ~0.8 s of silence pushes the last chunk through the cache-aware encoder.
            accept([Float](repeating: 0, count: Int(Double(sampleRate) * 0.8)))
            SherpaOnnxOnlineStreamInputFinished(stream)
            decodeAndPublish(notify: false)
            let text = currentText(recognizer: recognizer, stream: stream)
            let audioSeconds = Double(fedSamples) / Double(sampleRate)
            Logger.shared.log(
                "Nemotron session #\(sessionID) finished: audio_s=\(String(format: "%.2f", audioSeconds)), "
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
                Logger.shared.log("Nemotron session #\(sessionID) cancelled")
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
