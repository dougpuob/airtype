import Foundation

/// One local sherpa-onnx model the Settings ▸ Voice Input ▸ Local ASR pane can
/// download or remove. Behavior's Local Model list is this catalog: a model that is
/// not here is not offered there. Which model is used is chosen under Voice Input ▸ Behavior.
/// Paths and URLs match `scripts/setup-*.sh`. The app does
/// not shell out to those scripts (they are not in the bundle, and they install OpenCC).
struct LocalASRModel: Equatable {
    enum Source: Equatable {
        /// GitHub sherpa-onnx `asr-models` tarball. Extracts into `AirTypeHome.asrModels`.
        case archive(url: URL)
        /// Individual files (Qwen3-ASR 1.7B on ModelScope), each checked with SHA-256.
        case files(base: URL, items: [File])
    }

    struct File: Equatable {
        /// Path appended to the source base URL.
        var remotePath: String
        /// Path relative to the model directory.
        var relativePath: String
        var sha256: String
    }

    let kind: ASREngineKind
    /// Directory name under `~/.airtype/models/asr`, also the tarball stem.
    let directoryName: String
    /// When set and non-empty, the engine loads that path and this pane will not download into it.
    let envKey: String
    /// Files `load()` requires, relative to the model directory. Excludes the shared Silero VAD.
    let requiredFiles: [String]
    let needsVAD: Bool
    /// Unpacked size quoted by the setup scripts, for the settings row.
    let approximateSize: String
    let source: Source

    var title: String { kind.title }

    var isOverridden: Bool {
        let raw = ProcessInfo.processInfo.environment[envKey] ?? ""
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Where a download is written. Never an `AIRTYPE_*_MODEL_DIR` override.
    var installDirectory: URL {
        AirTypeHome.asrModels.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Where the engine will actually load this model (override wins).
    var statusDirectory: URL {
        switch kind {
        case .qwen3: return Qwen3ASREngine.modelDirectory
        case .qwen3Large: return Qwen3ASREngine.largeModelDirectory
        case .funasrNano: return Qwen3ASREngine.funASRModelDirectory
        case .senseVoice: return Qwen3ASREngine.senseVoiceModelDirectory
        case .zipformer: return Qwen3ASREngine.zipformerModelDirectory
        case .paraformer: return ParaformerStreamingEngine.modelDirectory
        case .nemotron: return NemotronStreamingEngine.modelDirectory
        case .remoteWhisper: return installDirectory
        }
    }

    func containsModelFiles(at directory: URL) -> Bool {
        let fm = FileManager.default
        return requiredFiles.allSatisfy { fm.fileExists(atPath: directory.appendingRelativePath($0).path) }
    }

    /// True when every file `load()` checks is already on disk, including Silero VAD.
    var isInstalled: Bool {
        guard containsModelFiles(at: statusDirectory) else { return false }
        if needsVAD, !FileManager.default.fileExists(atPath: LocalASRCatalog.vadURL.path) {
            return false
        }
        return true
    }
}

enum LocalASRCatalog {
    static let archiveBase = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/")!
    static let vadURL = AirTypeHome.asrModels.appendingPathComponent("silero_vad.onnx")
    static let vadDownloadURL = archiveBase.appendingPathComponent("silero_vad.onnx")

    static let models: [LocalASRModel] = [
        LocalASRModel(
            kind: .qwen3,
            directoryName: Qwen3ASREngine.defaultModelName,
            envKey: "AIRTYPE_QWEN3_MODEL_DIR",
            requiredFiles: [
                "conv_frontend.onnx",
                "encoder.int8.onnx",
                "decoder.int8.onnx",
                "tokenizer/vocab.json",
            ],
            needsVAD: true,
            approximateSize: "~800 MB",
            source: .archive(url: archiveBase.appendingPathComponent("\(Qwen3ASREngine.defaultModelName).tar.bz2"))
        ),
        LocalASRModel(
            kind: .qwen3Large,
            directoryName: Qwen3ASREngine.defaultLargeModelName,
            envKey: "AIRTYPE_QWEN3_1_7B_MODEL_DIR",
            requiredFiles: [
                "conv_frontend.onnx",
                "encoder.int8.onnx",
                "decoder.int8.onnx",
                "tokenizer/vocab.json",
            ],
            needsVAD: true,
            approximateSize: "~2.4 GB",
            source: .files(
                base: URL(string: "https://modelscope.cn/models/zengshuishui/Qwen3-ASR-onnx/resolve/master/")!,
                items: [
                    .init(remotePath: "model_1.7B/conv_frontend.onnx", relativePath: "conv_frontend.onnx", sha256: "fa894a4ba53da6a4238f2a6ca0b09362e505d39cecbd646051b033e2e8d7e2fb"),
                    .init(remotePath: "model_1.7B/encoder.int8.onnx", relativePath: "encoder.int8.onnx", sha256: "436fbd910a0c8914851e5ac1354e807be9f283d08a5da728adaa609731c41469"),
                    .init(remotePath: "model_1.7B/decoder.int8.onnx", relativePath: "decoder.int8.onnx", sha256: "c43c853fa6e97d08365cb8a5502b360b595cd43c00dc60e4d8ca7cc18cad460b"),
                    .init(remotePath: "tokenizer/vocab.json", relativePath: "tokenizer/vocab.json", sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
                    .init(remotePath: "tokenizer/merges.txt", relativePath: "tokenizer/merges.txt", sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
                    .init(remotePath: "tokenizer/tokenizer_config.json", relativePath: "tokenizer/tokenizer_config.json", sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
                ]
            )
        ),
        LocalASRModel(
            kind: .funasrNano,
            directoryName: Qwen3ASREngine.defaultFunASRModelName,
            envKey: "AIRTYPE_FUNASR_MODEL_DIR",
            requiredFiles: [
                "encoder_adaptor.int8.onnx",
                "llm.int8.onnx",
                "embedding.int8.onnx",
                "Qwen3-0.6B/vocab.json",
            ],
            needsVAD: true,
            approximateSize: "~840 MB",
            source: .archive(url: archiveBase.appendingPathComponent("\(Qwen3ASREngine.defaultFunASRModelName).tar.bz2"))
        ),
        LocalASRModel(
            kind: .senseVoice,
            directoryName: Qwen3ASREngine.defaultSenseVoiceModelName,
            envKey: "AIRTYPE_SENSEVOICE_MODEL_DIR",
            requiredFiles: ["model.int8.onnx", "tokens.txt"],
            needsVAD: true,
            approximateSize: "~155 MB",
            source: .archive(url: archiveBase.appendingPathComponent("\(Qwen3ASREngine.defaultSenseVoiceModelName).tar.bz2"))
        ),
        LocalASRModel(
            kind: .paraformer,
            directoryName: ParaformerStreamingEngine.defaultModelName,
            envKey: "AIRTYPE_PARAFORMER_MODEL_DIR",
            requiredFiles: ["encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt"],
            needsVAD: false,
            approximateSize: "~1 GB",
            source: .archive(url: archiveBase.appendingPathComponent("\(ParaformerStreamingEngine.defaultModelName).tar.bz2"))
        ),
        LocalASRModel(
            kind: .zipformer,
            directoryName: Qwen3ASREngine.defaultZipformerModelName,
            envKey: "AIRTYPE_ZIPFORMER_MODEL_DIR",
            requiredFiles: [
                Qwen3ASREngine.zipformerEncoderName,
                Qwen3ASREngine.zipformerDecoderName,
                Qwen3ASREngine.zipformerJoinerName,
                "tokens.txt",
            ],
            needsVAD: true,
            approximateSize: "~298 MB",
            source: .archive(url: archiveBase.appendingPathComponent("\(Qwen3ASREngine.defaultZipformerModelName).tar.bz2"))
        ),
        LocalASRModel(
            kind: .nemotron,
            directoryName: NemotronStreamingEngine.defaultModelName,
            envKey: "AIRTYPE_NEMOTRON_MODEL_DIR",
            requiredFiles: ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"],
            needsVAD: false,
            approximateSize: "~650 MB",
            source: .archive(url: archiveBase.appendingPathComponent("\(NemotronStreamingEngine.defaultModelName).tar.bz2"))
        ),
    ]

    static func model(for kind: ASREngineKind) -> LocalASRModel? {
        models.first { $0.kind == kind }
    }
}

extension URL {
    func appendingRelativePath(_ relative: String) -> URL {
        relative.split(separator: "/").reduce(self) { url, part in
            url.appendingPathComponent(String(part))
        }
    }
}
