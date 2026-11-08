import Foundation
import ServiceManagement

/// `AirType --selftest-wav <16kHz mono int16 wav> [zh-tw|zh-cn|en|auto-tw|auto-cn]`
/// Engine: AIRTYPE_ASR_ENGINE=qwen3|funasr-nano|sensevoice|paraformer|zipformer|nemotron|remote (default: menu choice, else qwen3).
/// Remote uses the app config's [localapp.remote-asr] / [localapp.backend-endpoint] / [webui.auth] (AIRTYPE_REMOTE_ENDPOINT overrides).
/// Streams a WAV through the same engine/formatter the hotkey path uses, printing partials, then exits.
enum SelfTest {
    /// `AirType --selftest-login-item [status|enable|disable]`: exercise SMAppService.mainApp
    /// (same API as the menu's Launch at Login) for this bundle, print the status, then exit.
    private static func runLoginItemTest(action: String) -> Never {
        let service = SMAppService.mainApp
        print("bundle: \(Bundle.main.bundleURL.path)")
        print("before: \(service.status.rawValue)")
        do {
            switch action {
            case "enable": try service.register()
            case "disable": try service.unregister()
            default: break
            }
        } catch {
            print("error: \(error.localizedDescription)")
        }
        let names: [Int: String] = [0: "notRegistered", 1: "enabled", 2: "requiresApproval", 3: "notFound"]
        print("after: \(service.status.rawValue) \(names[service.status.rawValue] ?? "unknown")")
        exit(0)
    }

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--selftest-login-item") {
            runLoginItemTest(action: index + 1 < args.count ? args[index + 1] : "status")
        }
        if args.contains("--selftest-config") {
            runConfigTest()
        }
        guard let index = args.firstIndex(of: "--selftest-wav"), index + 1 < args.count else { return false }
        let path = args[index + 1]
        let mode = index + 2 < args.count ? args[index + 2] : "zh-tw"
        let language = mode == "en" ? "en" : (mode.hasPrefix("auto") ? "auto" : "zh")
        guard let data = FileManager.default.contents(atPath: path), data.count > 44 else {
            print("cannot read \(path)")
            exit(2)
        }
        // Find the "data" chunk (afconvert adds extra chunks such as FLLR).
        var pcmStart = 44
        if let range = data.range(of: Data("data".utf8)) {
            pcmStart = range.upperBound + 4
        }
        let pcm = data.subdata(in: pcmStart..<data.count)
        let kind = ASREngineKind.current
        if kind.isRemote {
            let store = ConfigStore()
            try? store.load()
            RemoteWhisperSettings.configure(backend: store.config.backend, auth: store.config.webui.auth, remoteASR: store.config.remoteASR)
            let target = RemoteWhisperSettings.target(for: RemoteWhisperSettings.selectedEndpoint)
            print("remote endpoint: \(target.endpoint) protocol=\(target.protocolKind.rawValue) model=\(target.model)")
        }
        let engine = kind.makeEngine()
        print("engine: \(engine.kind.rawValue)")
        let done = DispatchSemaphore(value: 0)
        engine.load { state in
            guard state == .ready else { print("load failed: \(state)"); exit(1) }
            done.signal()
        }
        done.wait()
        let startedAt = Date()
        engine.startSession(language: kind.isRemote ? mode : language) { raw in
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            print("[partial +\(ms)ms] \(TranscriptFormatter.format(raw, mode: mode))")
        }
        // 100 ms chunks, paced in real time like the microphone.
        let chunkBytes = 1600 * 2
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + chunkBytes, pcm.count)
            engine.feed(pcm.subdata(in: offset..<end))
            offset = end
            Thread.sleep(forTimeInterval: 0.1)
        }
        let stopAt = Date()
        engine.finish { raw in
            let ms = Int(Date().timeIntervalSince(stopAt) * 1000)
            print("[final, \(ms)ms after stop] \(TranscriptFormatter.format(raw, mode: mode))")
            done.signal()
        }
        done.wait()
        exit(0)
    }

    /// `AirType --selftest-config`: lists models for [localapp.remote-asr] (as Settings ▸ Fetch Models does),
    /// then rewrites config.json through the same save path as the Settings window and exits.
    private static func runConfigTest() -> Never {
        let store = ConfigStore()
        do { try store.load() } catch { print("load failed: \(error)"); exit(1) }
        let remote = store.config.remoteASR
        let target = RemoteASRTarget(
            endpoint: RemoteWhisperSettings.normalize(remote.endpoint) ?? store.config.backend.remoteEndpoint,
            protocolKind: RemoteASRProtocol(rawValue: remote.protocolName) ?? .webuiIME,
            model: remote.model, apiKey: remote.apiKey, auth: store.config.webui.auth)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let list = await BackendClient().listRemoteModels(target: target)
            print("models endpoint=\(target.endpoint) protocol=\(list.detectedProtocol?.rawValue ?? "none") count=\(list.models.count)")
            print("models: \(list.models.joined(separator: ", "))")
            print("note: \(list.note)")
            done.signal()
        }
        done.wait()
        store.replaceAndSave(store.config)
        print("saved: \(store.filePath)")
        exit(0)
    }
}
