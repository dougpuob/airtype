import CSherpaOnnx
import Foundation

/// Local Qwen3-ASR (0.6B int8, sherpa-onnx offline recognizer) made "pseudo-streaming":
///
/// - Silero VAD splits the microphone audio at pauses. Every closed speech segment is decoded once
///   and committed (it no longer changes).
/// - While you are still talking, the open (not yet committed) audio is re-decoded about every
///   `partialInterval` seconds so the panel / live typing shows a draft that can still be revised.
/// - On stop the remaining open audio is decoded once more and appended.
///
/// So text appears in bursts (per pause / ~1 s), not word by word like Nemotron.
///
/// The same VAD + re-decode loop also drives Fun-ASR-Nano (sherpa-onnx `funasr_nano`, also an
/// audio-encoder + Qwen3-0.6B LLM decoder, offline only); `model` picks which one is loaded.
final class Qwen3ASREngine: ASREngine, @unchecked Sendable {
    enum Model {
        case qwen3
        case qwen3Large
        case funasrNano

        /// Both Qwen3-ASR sizes share the sherpa `qwen3_asr` config, env knobs and hotwords file.
        var isQwen3: Bool { self != .funasrNano }
    }

    let model: Model
    var kind: ASREngineKind {
        switch model {
        case .qwen3: return .qwen3
        case .qwen3Large: return .qwen3Large
        case .funasrNano: return .funasrNano
        }
    }
    private var name: String { kind.shortName }

    init(model: Model = .qwen3) {
        self.model = model
        let prefix = model.isQwen3 ? "AIRTYPE_QWEN3_" : "AIRTYPE_FUNASR_"
        partialInterval = Self.envDouble(prefix + "PARTIAL_SECONDS", 1.0)
        minSilence = Float(Self.envDouble(prefix + "MIN_SILENCE", 0.5))
        maxSegment = Float(Self.envDouble(prefix + "MAX_SEGMENT", 15.0))
        threads = Int32(ProcessInfo.processInfo.environment[prefix + "THREADS"].flatMap { Int($0) } ?? 4)
    }

    static let defaultModelName = "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25"
    static let defaultLargeModelName = "qwen3-asr-1.7B-int8"
    static let defaultFunASRModelName = "sherpa-onnx-funasr-nano-int8-2025-12-30"

    static var funASRModelDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AIRTYPE_FUNASR_MODEL_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return experimentDirectory.appendingPathComponent("models").appendingPathComponent(defaultFunASRModelName)
    }

    static var funASRHotwordsFile: URL {
        experimentDirectory.appendingPathComponent("funasr-hotwords.txt")
    }

    static var experimentDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".airtype-experiment")
    }

    static var modelDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AIRTYPE_QWEN3_MODEL_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return experimentDirectory.appendingPathComponent("models").appendingPathComponent(defaultModelName)
    }

    /// Qwen3-ASR 1.7B int8 (ModelScope zengshuishui/Qwen3-ASR-onnx model_1.7B; scripts/setup-qwen3-1.7b.sh).
    static var largeModelDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AIRTYPE_QWEN3_1_7B_MODEL_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return experimentDirectory.appendingPathComponent("models").appendingPathComponent(defaultLargeModelName)
    }

    static var vadModelPath: URL {
        experimentDirectory.appendingPathComponent("models/silero_vad.onnx")
    }

    /// Optional: one term per line (or comma separated), e.g. product names / English jargon.
    static var hotwordsFile: URL {
        experimentDirectory.appendingPathComponent("qwen3-hotwords.txt")
    }

    private static func envDouble(_ key: String, _ fallback: Double) -> Double {
        guard let raw = ProcessInfo.processInfo.environment[key], let value = Double(raw) else { return fallback }
        return value
    }

    private let queue = DispatchQueue(label: "airtype.offline-llm-asr.engine", qos: .userInitiated)
    private let sampleRate: Int32 = 16_000
    private let partialInterval: Double
    private let minSilence: Float
    private let maxSegment: Float
    private let threads: Int32

    private var recognizer: OpaquePointer?
    private var vad: OpaquePointer?

    // Session state (queue only).
    private var active = false
    private var sessionID = 0
    private var onUpdate: ((String) -> Void)?
    private var audio: [Float] = []          // all samples of this session
    private var committedUpTo = 0            // samples before this index are covered by committed text
    private var committedText = ""
    private var openText = ""                // latest draft for audio after committedUpTo
    private var lastPublished = ""
    private var lastPartialAt = 0            // sample index of the last partial decode
    private var speechSinceCommit = false
    private var decodeSeconds = 0.0
    private var decodeCount = 0

    private let stateLock = NSLock()
    private var _state: ASREngineState = .notLoaded
    var state: ASREngineState {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }
    private func setState(_ value: ASREngineState) {
        stateLock.lock(); _state = value; stateLock.unlock()
    }

    deinit {
        if let vad { SherpaOnnxDestroyVoiceActivityDetector(vad) }
        if let recognizer { SherpaOnnxDestroyOfflineRecognizer(recognizer) }
    }

    func load(completion: @escaping (ASREngineState) -> Void) {
        queue.async { [self] in
            if recognizer != nil, vad != nil {
                completion(.ready)
                return
            }
            setState(.loading)
            let dir: URL
            switch model {
            case .qwen3: dir = Self.modelDirectory
            case .qwen3Large: dir = Self.largeModelDirectory
            case .funasrNano: dir = Self.funASRModelDirectory
            }
            let required: [URL]
            switch model {
            case .qwen3, .qwen3Large:
                required = [
                    dir.appendingPathComponent("conv_frontend.onnx"),
                    dir.appendingPathComponent("encoder.int8.onnx"),
                    dir.appendingPathComponent("decoder.int8.onnx"),
                    dir.appendingPathComponent("tokenizer/vocab.json"),
                    Self.vadModelPath,
                ]
            case .funasrNano:
                required = [
                    dir.appendingPathComponent("encoder_adaptor.int8.onnx"),
                    dir.appendingPathComponent("llm.int8.onnx"),
                    dir.appendingPathComponent("embedding.int8.onnx"),
                    dir.appendingPathComponent("Qwen3-0.6B/vocab.json"),
                    Self.vadModelPath,
                ]
            }
            let setupScript: String
            switch model {
            case .qwen3: setupScript = "scripts/setup-qwen3.sh"
            case .qwen3Large: setupScript = "scripts/setup-qwen3-1.7b.sh"
            case .funasrNano: setupScript = "scripts/setup-funasr-nano.sh"
            }
            for file in required where !FileManager.default.fileExists(atPath: file.path) {
                let message = "\(name) file missing: \(file.path) (run \(setupScript))"
                Logger.shared.log(message)
                setState(.failed(message))
                completion(.failed(message))
                return
            }

            let startedAt = Date()
            let hotwords = Self.loadHotwords(model)
            var owned: [UnsafeMutablePointer<CChar>] = []
            func c(_ s: String) -> UnsafePointer<CChar> {
                let p = strdup(s)!
                owned.append(p)
                return UnsafePointer(p)
            }
            defer { owned.forEach { free($0) } }

            var config = SherpaOnnxOfflineRecognizerConfig()
            memset(&config, 0, MemoryLayout<SherpaOnnxOfflineRecognizerConfig>.size)
            config.feat_config.sample_rate = sampleRate
            config.feat_config.feature_dim = 80
            switch model {
            case .qwen3, .qwen3Large:
                config.model_config.qwen3_asr.conv_frontend = c(dir.appendingPathComponent("conv_frontend.onnx").path)
                config.model_config.qwen3_asr.encoder = c(dir.appendingPathComponent("encoder.int8.onnx").path)
                config.model_config.qwen3_asr.decoder = c(dir.appendingPathComponent("decoder.int8.onnx").path)
                config.model_config.qwen3_asr.tokenizer = c(dir.appendingPathComponent("tokenizer").path)
                config.model_config.qwen3_asr.max_total_len = 512
                config.model_config.qwen3_asr.max_new_tokens = 256
                config.model_config.qwen3_asr.temperature = 1e-6
                config.model_config.qwen3_asr.top_p = 0.8
                config.model_config.qwen3_asr.seed = 42
                config.model_config.qwen3_asr.hotwords = c(hotwords)
            case .funasrNano:
                let env = ProcessInfo.processInfo.environment
                config.model_config.funasr_nano.encoder_adaptor = c(dir.appendingPathComponent("encoder_adaptor.int8.onnx").path)
                config.model_config.funasr_nano.llm = c(dir.appendingPathComponent("llm.int8.onnx").path)
                config.model_config.funasr_nano.embedding = c(dir.appendingPathComponent("embedding.int8.onnx").path)
                config.model_config.funasr_nano.tokenizer = c(dir.appendingPathComponent("Qwen3-0.6B").path)
                config.model_config.funasr_nano.system_prompt = c("You are a helpful assistant.")
                config.model_config.funasr_nano.user_prompt = c("语音转写：")
                config.model_config.funasr_nano.max_new_tokens = 256
                config.model_config.funasr_nano.temperature = 1e-6
                config.model_config.funasr_nano.top_p = 0.8
                config.model_config.funasr_nano.seed = 42
                // "" = auto (zh / en / ja / mixed). Set e.g. AIRTYPE_FUNASR_LANGUAGE=中文 to force.
                config.model_config.funasr_nano.language = c(env["AIRTYPE_FUNASR_LANGUAGE"] ?? "")
                // ITN on: punctuation + digits ("二零二六" -> "2026"). AIRTYPE_FUNASR_ITN=0 disables.
                config.model_config.funasr_nano.itn = env["AIRTYPE_FUNASR_ITN"] == "0" ? 0 : 1
                config.model_config.funasr_nano.hotwords = c(hotwords)
            }
            config.model_config.tokens = c("")
            config.model_config.num_threads = threads
            config.model_config.provider = c("cpu")
            config.decoding_method = c("greedy_search")

            guard let created = SherpaOnnxCreateOfflineRecognizer(&config) else {
                let message = "SherpaOnnxCreateOfflineRecognizer failed for \(name) (model dir: \(dir.path))"
                Logger.shared.log(message)
                setState(.failed(message))
                completion(.failed(message))
                return
            }
            recognizer = created

            var vadConfig = SherpaOnnxVadModelConfig()
            memset(&vadConfig, 0, MemoryLayout<SherpaOnnxVadModelConfig>.size)
            vadConfig.silero_vad.model = c(Self.vadModelPath.path)
            vadConfig.silero_vad.threshold = 0.4
            vadConfig.silero_vad.min_silence_duration = minSilence
            vadConfig.silero_vad.min_speech_duration = 0.2
            vadConfig.silero_vad.max_speech_duration = maxSegment
            vadConfig.silero_vad.window_size = 512
            vadConfig.sample_rate = sampleRate
            vadConfig.num_threads = 1
            vadConfig.provider = c("cpu")
            guard let createdVad = SherpaOnnxCreateVoiceActivityDetector(&vadConfig, 60) else {
                let message = "SherpaOnnxCreateVoiceActivityDetector failed (\(Self.vadModelPath.path))"
                Logger.shared.log(message)
                setState(.failed(message))
                completion(.failed(message))
                return
            }
            vad = createdVad

            // Warm-up decode so the first real utterance is not slow.
            _ = decode([Float](repeating: 0, count: Int(sampleRate) / 2))
            decodeSeconds = 0; decodeCount = 0

            setState(.ready)
            Logger.shared.log(
                "\(name) recognizer ready: model_dir=\(dir.path), hotwords=\(hotwords.isEmpty ? 0 : hotwords.split(separator: ",").count), "
                + "load_ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
            )
            completion(.ready)
        }
    }

    /// `language` is ignored: Qwen3-ASR / Fun-ASR-Nano detect zh / en / mixed by themselves.
    func startSession(language: String, onUpdate: @escaping (String) -> Void) {
        queue.async { [self] in
            guard recognizer != nil, let vad else {
                Logger.shared.log("\(name) session not started: recognizer not loaded")
                return
            }
            SherpaOnnxVoiceActivityDetectorReset(vad)
            sessionID += 1
            active = true
            self.onUpdate = onUpdate
            audio.removeAll(keepingCapacity: true)
            committedUpTo = 0
            committedText = ""
            openText = ""
            lastPublished = ""
            lastPartialAt = 0
            speechSinceCommit = false
            decodeSeconds = 0
            decodeCount = 0
            Logger.shared.log("\(name) session #\(sessionID) started (language hint \(language) ignored; auto zh/en)")
        }
    }

    func feed(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        queue.async { [self] in
            guard active, let vad else { return }
            let samples = Self.floatSamples(from: pcm)
            audio.append(contentsOf: samples)
            samples.withUnsafeBufferPointer { buffer in
                SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, buffer.baseAddress, Int32(buffer.count))
            }
            if SherpaOnnxVoiceActivityDetectorDetected(vad) == 1 {
                speechSinceCommit = true
            }
            let committedAny = drainSegments()
            if committedAny {
                publish()
                return
            }
            // Re-decode the open audio for a draft, at most every partialInterval seconds of new audio.
            let interval = Int(partialInterval * Double(sampleRate))
            if speechSinceCommit, audio.count - lastPartialAt >= interval, audio.count - committedUpTo >= Int(sampleRate) / 2 {
                lastPartialAt = audio.count
                openText = decode(Array(audio[committedUpTo...]))
                publish()
            }
        }
    }

    func finish(completion: @escaping (String) -> Void) {
        queue.async { [self] in
            guard active, let vad else {
                completion(lastPublished)
                return
            }
            SherpaOnnxVoiceActivityDetectorFlush(vad)
            _ = drainSegments()
            // Whatever is left after the last committed segment (speech still open at stop).
            if speechSinceCommit, audio.count - committedUpTo >= Int(sampleRate) / 5 {
                let tail = decode(Array(audio[committedUpTo...]))
                committedText = Self.join(committedText, tail)
            }
            committedUpTo = audio.count
            openText = ""
            let text = committedText
            Logger.shared.log(
                "\(name) session #\(sessionID) finished: audio_s=\(String(format: "%.2f", Double(audio.count) / Double(sampleRate))), "
                + "decodes=\(decodeCount), decode_s=\(String(format: "%.3f", decodeSeconds)), chars=\(text.count)"
            )
            active = false
            onUpdate = nil
            audio.removeAll(keepingCapacity: false)
            SherpaOnnxVoiceActivityDetectorReset(vad)
            completion(text)
        }
    }

    func cancel() {
        queue.async { [self] in
            if active {
                Logger.shared.log("\(name) session #\(sessionID) cancelled")
            }
            active = false
            onUpdate = nil
            audio.removeAll(keepingCapacity: false)
            if let vad { SherpaOnnxVoiceActivityDetectorReset(vad) }
        }
    }

    // MARK: - Queue-only helpers

    /// Commits every closed VAD segment. Returns true if anything was committed.
    private func drainSegments() -> Bool {
        guard let vad else { return false }
        var committed = false
        while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
            guard let segment = SherpaOnnxVoiceActivityDetectorFront(vad) else { break }
            let start = Int(segment.pointee.start)
            let count = Int(segment.pointee.n)
            SherpaOnnxDestroySpeechSegment(segment)
            SherpaOnnxVoiceActivityDetectorPop(vad)
            let end = min(start + count, audio.count)
            guard count > 0, end > committedUpTo else { continue }
            // Decode from our own buffer with ~0.4 s lead-in: Silero tends to clip the first syllable.
            let from = max(committedUpTo, start - Int(sampleRate) * 2 / 5)
            let text = decode(Array(audio[from..<end]))
            committedText = Self.join(committedText, text)
            committedUpTo = end
            lastPartialAt = committedUpTo
            openText = ""
            speechSinceCommit = false
            committed = true
        }
        return committed
    }

    private func publish() {
        let text = Self.join(committedText, openText)
        guard text != lastPublished else { return }
        lastPublished = text
        onUpdate?(text)
    }

    private func decode(_ samples: [Float]) -> String {
        guard let recognizer, !samples.isEmpty else { return "" }
        let startedAt = Date()
        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return "" }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxAcceptWaveformOffline(stream, sampleRate, buffer.baseAddress, Int32(buffer.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        var text = ""
        if let result = SherpaOnnxGetOfflineStreamResult(stream) {
            if let cText = result.pointee.text { text = String(cString: cText) }
            SherpaOnnxDestroyOfflineRecognizerResult(result)
        }
        decodeSeconds += Date().timeIntervalSince(startedAt)
        decodeCount += 1
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Joins two recognized pieces: no space next to CJK / full-width punctuation, one space between Latin words.
    static func join(_ lhs: String, _ rhs: String) -> String {
        if lhs.isEmpty { return rhs }
        if rhs.isEmpty { return lhs }
        guard let last = lhs.last, let first = rhs.first else { return lhs + rhs }
        if TranscriptFormatter.isCJK(last) || TranscriptFormatter.isCJK(first) {
            return lhs + rhs
        }
        return lhs + " " + rhs
    }

    private static func loadHotwords(_ model: Model) -> String {
        let envKey = model.isQwen3 ? "AIRTYPE_QWEN3_HOTWORDS" : "AIRTYPE_FUNASR_HOTWORDS"
        if let env = ProcessInfo.processInfo.environment[envKey], !env.isEmpty {
            return env
        }
        // Fun-ASR-Nano falls back to the Qwen3 list so one file can serve both engines.
        let file = model == .funasrNano && FileManager.default.fileExists(atPath: funASRHotwordsFile.path)
            ? funASRHotwordsFile : hotwordsFile
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return "" }
        let words = raw
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return words.joined(separator: ",")
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
