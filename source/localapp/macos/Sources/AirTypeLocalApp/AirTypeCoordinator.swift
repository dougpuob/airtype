import AppKit
import AVFoundation
import Foundation
import ServiceManagement

@MainActor
final class AirTypeCoordinator: NSObject, ObservableObject, NSMenuDelegate {
    private let configStore = ConfigStore()
    private let audioRecorder = AudioRecorder()
    private let pasteController = PasteController()
    // Merged former localapp + localapp2. ASR Engine ▸ Local (sherpa-onnx in-process: Qwen3-ASR / Fun-ASR-Nano /
    // Nemotron; default Qwen3-ASR) or ▸ Remote (WebUI /api/transcribe/ime → whisper-server, from localapp).
    // Recreated in start() once the config (remote endpoints / auth) is loaded.
    private var engine: ASREngine = ASREngineKind.current.makeEngine()
    private let liveTyper = LiveTyper()
    private var engineState: ASREngineState = .notLoaded
    private var liveTargetPID: pid_t?
    private var latestDisplayText = ""
    private static let liveTypingDefaultsKey = "liveTypingEnabled"
    private var liveTypingEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.liveTypingDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.liveTypingDefaultsKey) }
    }
    /// Remote Whisper has no partial results, so it always pastes on stop (the Live Typing setting is kept).
    private var liveTypingActive: Bool { liveTypingEnabled && !engine.kind.isRemote }
    private var statusItem: NSStatusItem?
    private weak var microphoneDeviceMenu: NSMenu?
    private weak var statusMenu: NSMenu?
    private weak var launchAtLoginItem: NSMenuItem?
    private var hotkeyMonitor: HotkeyMonitor?
    private var floatingPanel: FloatingPanelController?
    private var timedMicrophoneReleaseTimer: Timer?
    private var targetApp: RunningAppIdentity?
    private var nextInputID = 1
    private var activeInputID: Int?
    private var activeInputStartedAt: Date?
    private enum RecordingState {
        case idle
        case preparing
        case recording
    }
    private var recordingState: RecordingState = .idle
    private var settingsWindow: SettingsWindowController?

    func start() {
        do {
            try configStore.load()
        } catch {
            Logger.shared.log(error.localizedDescription)
            showStartupError(error.localizedDescription)
            NSApp.terminate(nil)
            return
        }
        migrateLegacyMicrophoneSelection()
        configureRemoteSettings()
        if engine.kind.isRemote {
            engine = ASREngineKind.remoteWhisper.makeEngine()
        }
        loadEngine()
        if configStore.config.microphone.mode == "always" {
            audioRecorder.prepare(
                microphoneDeviceName: configStore.config.microphone.selectedDeviceName,
                preRollSeconds: configStore.config.microphone.preRollSeconds
            )
        }
        setupStatusItem()
        setupFloatingPanel()
        refreshMicrophoneAvailability()
        scheduleTimedMicrophoneRelease(reason: "startup")
        setupHotkey()
    }

    private func showStartupError(_ message: String) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "AirType cannot start"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
    }

    func stop() {
        timedMicrophoneReleaseTimer?.invalidate()
        timedMicrophoneReleaseTimer = nil
        hotkeyMonitor?.stop()
        audioRecorder.stop()
        engine.cancel()
    }

    private func loadEngine() {
        engineState = .loading
        engine.load { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                self.engineState = state
                self.rebuildMenu()
                if case .failed(let message) = state {
                    let hint = self.engine.kind.isRemote ? "Remote ASR unreachable" : "\(self.engine.kind.shortName) model missing"
                    self.floatingPanel?.showMicrophoneError(hint)
                    Logger.shared.log("\(self.engine.kind.shortName) engine failed to load: \(message)")
                }
            }
        }
    }

    /// Remote endpoint list / auth come from [localapp.backend-endpoint] + [webui.auth] of the app config
    /// (~/.airtype-experiment/config.toml, seeded from ~/.airtype/config.toml); AIRTYPE_REMOTE_ENDPOINT overrides.
    private func configureRemoteSettings() {
        RemoteWhisperSettings.configure(
            backend: configStore.config.backend,
            auth: configStore.config.webui.auth,
            remoteASR: configStore.config.remoteASR
        )
    }

    private var recognitionLanguage: String {
        switch configStore.config.chineseMode.mode {
        case "en": return "en"
        case "auto", "auto-tw", "auto-cn": return "auto"
        default: return "zh"
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = StatusIcon.make(recording: false)
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "AirType (\(engine.kind.shortName))"
        statusItem = item
        rebuildMenu()
    }

    private func setupFloatingPanel() {
        floatingPanel = FloatingPanelController(
            configStore: configStore,
            onMove: { [weak self] xRatio, yRatio in
                self?.configStore.updateFloatingPosition(xRatio: xRatio, yRatio: yRatio)
            }
        )
    }

    private func setupHotkey() {
        hotkeyMonitor = HotkeyMonitor(
            onDoublePress: { [weak self] in
                Task { @MainActor in
                    self?.toggleRecording()
                }
            },
            onEscape: { [weak self] in
                Task { @MainActor in
                    self?.cancelRecording()
                }
            }
        )
        hotkeyMonitor?.start()
    }

    private func migrateLegacyMicrophoneSelection() {
        let selected = configStore.config.microphone.selectedDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let order = Int(selected), order > 0 else { return }

        let devices = AudioRecorder.inputDevices()
        let index = order - 1
        guard devices.indices.contains(index) else {
            Logger.shared.log("Legacy microphone order could not be migrated: selected_order=\(selected)")
            return
        }

        let deviceName = devices[index].localizedName
        configStore.updateMicrophoneDeviceName(deviceName)
        Logger.shared.log("Migrated microphone selection from order \(selected) to device name: \(deviceName)")
    }

    private func applyMicrophoneRuntimeSettings(reason: String) {
        let config = configStore.config
        cancelTimedMicrophoneRelease()
        Logger.shared.log(
            "Applying microphone settings: reason=\(reason), mode=\(config.microphone.mode), "
            + "selected_device_name=\(config.microphone.selectedDeviceName.isEmpty ? "default" : config.microphone.selectedDeviceName), "
            + "always_on_timeout_minutes=\(config.microphone.alwaysOnTimeoutMinutes), "
            + "pre_roll_seconds=\(config.microphone.preRollSeconds)"
        )

        // Recording will only stop when the current device is unavailable (e.g., the device is removed).
        // If a new device is added, recording will continue; users can switch between devices in the menu.
        let currentDeviceAvailable = audioRecorder.isCurrentDeviceAvailable()

        if recordingState == .preparing || recordingState == .recording {
            if !currentDeviceAvailable {
                Logger.shared.log("Recording is active but microphone was removed; stopping current recording before applying settings")
                stopRecording()
            } else {
                Logger.shared.log("Recording is active while microphone settings changed; continuing recording (device still available)")
                return
            }
        }

        audioRecorder.stop()
        if config.microphone.mode == "always" {
            audioRecorder.prepare(
                microphoneDeviceName: config.microphone.selectedDeviceName,
                preRollSeconds: config.microphone.preRollSeconds
            )
        }
        scheduleTimedMicrophoneRelease(reason: reason)
    }

    private func cancelTimedMicrophoneRelease() {
        timedMicrophoneReleaseTimer?.invalidate()
        timedMicrophoneReleaseTimer = nil
    }

    private func scheduleTimedMicrophoneRelease(reason: String) {
        cancelTimedMicrophoneRelease()
        let timeoutMinutes = configStore.config.microphone.alwaysOnTimeoutMinutes
        guard configStore.config.microphone.mode == "always", timeoutMinutes > 0 else { return }
        guard recordingState == .idle else { return }
        guard audioRecorder.isPreparedForInput() else { return }
        let timeoutInterval = TimeInterval(timeoutMinutes * 60)

        let timer = Timer(timeInterval: timeoutInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.releaseTimedMicrophoneIfIdle()
            }
        }
        timedMicrophoneReleaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        Logger.shared.log(
            "Scheduled Always On microphone release: reason=\(reason), "
            + "timeout_minutes=\(timeoutMinutes)"
        )
    }

    private func releaseTimedMicrophoneIfIdle() {
        timedMicrophoneReleaseTimer = nil
        let timeoutMinutes = configStore.config.microphone.alwaysOnTimeoutMinutes
        guard configStore.config.microphone.mode == "always", timeoutMinutes > 0 else { return }
        guard recordingState == .idle else {
            scheduleTimedMicrophoneRelease(reason: "recording_active_at_timeout")
            return
        }
        audioRecorder.stop()
        Logger.shared.log(
            "Released Always On microphone after \(timeoutMinutes) minutes of inactivity"
        )
    }

    private func microphoneAvailabilityIssue(devices: [AVCaptureDevice]) -> String? {
        guard !devices.isEmpty else {
            return "No microphone device found"
        }

        let selectedDeviceName = configStore.config.microphone.selectedDeviceName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedDeviceName.isEmpty else { return nil }
        guard devices.contains(where: { $0.localizedName == selectedDeviceName }) else {
            return "Microphone device missing"
        }
        return nil
    }

    @discardableResult
    private func refreshMicrophoneAvailability(
        devices: [AVCaptureDevice] = AudioRecorder.inputDevices(),
        playErrorSound: Bool = false,
        reason: String = "refresh"
    ) -> Bool {
        guard let issue = microphoneAvailabilityIssue(devices: devices) else {
            floatingPanel?.clearMicrophoneError()
            return true
        }

        let selectedDeviceName = configStore.config.microphone.selectedDeviceName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Logger.shared.log(
            "Microphone unavailable: reason=\(reason), issue=\(issue), "
            + "selected_device_name=\(selectedDeviceName.isEmpty ? "system_default" : selectedDeviceName), "
            + "available_device_count=\(devices.count)"
        )
        floatingPanel?.showMicrophoneError(issue)
        if playErrorSound {
            NSSound.beep()
        }
        return false
    }

    private func toggleRecording() {
        if recordingState == .recording || recordingState == .preparing {
            stopRecording()
        } else {
            guard refreshMicrophoneAvailability(
                playErrorSound: true,
                reason: "recording_hotkey"
            ) else { return }
            startRecording()
        }
    }

    private func startRecording() {
        cancelTimedMicrophoneRelease()
        let inputID = nextInputID
        nextInputID += 1
        activeInputID = inputID
        activeInputStartedAt = Date()
        Logger.shared.blankLine()
        Logger.shared.log("========== INPUT #\(inputID) START ==========")
        Logger.shared.log("Input #\(inputID): first hotkey double-press received; recording flow started")
        targetApp = RunningAppIdentity.frontmost()
        recordingState = .preparing
        statusItem?.button?.image = StatusIcon.make(recording: true)
        floatingPanel?.showPreparing()

        let config = configStore.config
        let requiresWarmup = config.microphone.mode == "on_demand"
            || !audioRecorder.isPreparedForInput()
        let warmupDelay: TimeInterval = requiresWarmup ? 0.7 : 0
        if requiresWarmup {
            Logger.shared.log(
                "Input #\(inputID): microphone warmup requested: "
                + "mode=\(config.microphone.mode), delay_ms=\(Int(warmupDelay * 1000))"
            )
            DispatchQueue.global(qos: .userInitiated).async { [audioRecorder] in
                audioRecorder.prepare(
                    microphoneDeviceName: config.microphone.selectedDeviceName,
                    preRollSeconds: config.microphone.preRollSeconds
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.recordingState == .preparing, self.activeInputID == inputID else {
                        audioRecorder.stop()
                        return
                    }
                    Logger.shared.log("Input #\(inputID): microphone warmup ready")
                    DispatchQueue.main.asyncAfter(deadline: .now() + warmupDelay) { [weak self] in
                        self?.beginRecordingIfStillPreparing(inputID: inputID)
                    }
                }
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + warmupDelay) { [weak self] in
            self?.beginRecordingIfStillPreparing(inputID: inputID)
        }
    }

    private func beginRecordingIfStillPreparing(inputID expectedInputID: Int) {
        guard recordingState == .preparing else { return }
        guard activeInputID == expectedInputID else { return }
        guard engineState == .ready else {
            Logger.shared.log("\(inputLogPrefix(activeInputID))\(engine.kind.shortName) engine not ready: \(engineState)")
            if engine.kind.isRemote, case .failed = engineState {
                loadEngine() // re-check the remote server so the next try can work without a menu click
            }
            NSSound.beep()
            recordingState = .idle
            statusItem?.button?.image = StatusIcon.make(recording: false)
            floatingPanel?.hide()
            audioRecorder.stop()
            finishInput(activeInputID, startedAt: activeInputStartedAt, result: "SKIPPED", details: "reason=engine_not_ready")
            return
        }
        guard refreshMicrophoneAvailability(
            playErrorSound: true,
            reason: "recording_begin"
        ) else {
            let inputID = activeInputID
            let inputStartedAt = activeInputStartedAt
            recordingState = .idle
            statusItem?.button?.image = StatusIcon.make(recording: false)
            audioRecorder.stop()
            finishInput(
                inputID,
                startedAt: inputStartedAt,
                result: "SKIPPED",
                details: "reason=microphone_unavailable"
            )
            return
        }
        let config = configStore.config
        let inputID = activeInputID
        recordingState = .recording
        floatingPanel?.showRecording()
        liveTyper.reset()
        latestDisplayText = ""
        liveTargetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let mode = config.chineseMode.mode
        // Remote gets the raw chinese-mode (zh-tw / zh-cn / en / auto-*) and maps it to WebUI languages itself.
        let sessionLanguage = engine.kind.isRemote ? mode : recognitionLanguage
        engine.startSession(language: sessionLanguage) { [weak self] raw in
            DispatchQueue.main.async {
                self?.handlePartial(raw: raw, mode: mode, inputID: inputID)
            }
        }
        let engine: ASREngine = engine
        audioRecorder.start(
            microphoneDeviceName: config.microphone.selectedDeviceName,
            preRollSeconds: config.microphone.preRollSeconds,
            onLevel: { [weak self] level in
                Task { @MainActor in self?.floatingPanel?.setLevel(level) }
            },
            onPCM: { pcm in engine.feed(pcm) }
        )
        Logger.shared.log(
            "\(inputLogPrefix(inputID))streaming capture active: microphone_mode=\(config.microphone.mode), "
            + "pre_roll_seconds=\(config.microphone.preRollSeconds), language=\(sessionLanguage), "
            + "engine=\(engine.kind.rawValue), output=\(liveTypingActive ? "live_typing" : "paste_on_stop")"
        )
    }

    private var targetIsFrontmost: Bool {
        guard let liveTargetPID else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == liveTargetPID
    }

    private func handlePartial(raw: String, mode: String, inputID: Int?) {
        guard recordingState == .recording, activeInputID == inputID else { return }
        let display = TranscriptFormatter.format(raw, mode: mode)
        latestDisplayText = display
        floatingPanel?.setPartialText(display)
        if liveTypingActive, targetIsFrontmost, AXIsProcessTrusted() {
            liveTyper.apply(display)
        }
    }

    private func stopRecording() {
        let inputID = activeInputID
        let inputStartedAt = activeInputStartedAt
        Logger.shared.log("\(inputLogPrefix(inputID))second hotkey double-press received; recording stop requested")
        let wasRecording = recordingState == .recording
        recordingState = .idle
        defer {
            scheduleTimedMicrophoneRelease(reason: "recording_stopped")
        }
        statusItem?.button?.image = StatusIcon.make(recording: false)

        if !wasRecording {
            floatingPanel?.hide()
            if configStore.config.microphone.mode == "on_demand" {
                audioRecorder.stop()
            }
            Logger.shared.log("\(inputLogPrefix(inputID))recording cancelled before capture became active")
            finishInput(inputID, startedAt: inputStartedAt, result: "SKIPPED", details: "reason=stopped_before_capture")
            return
        }

        audioRecorder.stopStreaming()
        if configStore.config.microphone.mode == "on_demand" {
            audioRecorder.stop()
        }

        let mode = configStore.config.chineseMode.mode
        let targetApp = targetApp
        floatingPanel?.showFinalizing()
        Logger.shared.log("\(inputLogPrefix(inputID))recording stopped; finalizing \(engine.kind.shortName) session")
        engine.finish { [weak self] raw in
            DispatchQueue.main.async {
                guard let self else { return }
                let finalText = TranscriptFormatter.format(raw, mode: mode)
                guard TextPolisher.enabled, !finalText.isEmpty else {
                    self.deliverFinal(finalText, targetApp: targetApp, inputID: inputID, startedAt: inputStartedAt)
                    return
                }
                // 停錄後 LLM 整理 (local oMLX, thinking off). On any failure paste the original ASR text.
                Logger.shared.log("\(self.inputLogPrefix(inputID))LLM polish requested chars=\(finalText.count)")
                TextPolisher.polish(finalText, llm: self.configStore.config.webui.llm) { polished in
                    DispatchQueue.main.async {
                        let output = polished.map { TranscriptFormatter.format($0, mode: mode, fixEnglishCase: false) } ?? finalText
                        self.deliverFinal(output.isEmpty ? finalText : output, targetApp: targetApp, inputID: inputID, startedAt: inputStartedAt)
                    }
                }
            }
        }
    }

    private func deliverFinal(_ finalText: String, targetApp: RunningAppIdentity?, inputID: Int?, startedAt: Date?) {
        Logger.shared.log("\(inputLogPrefix(inputID))final transcript chars=\(finalText.count)")
        if liveTypingActive, targetIsFrontmost, AXIsProcessTrusted() {
            liveTyper.apply(finalText)
            floatingPanel?.hide()
            finishInput(inputID, startedAt: startedAt, result: "COMPLETE", details: "output=live_typing, chars=\(finalText.count)")
            return
        }

        // Paste-on-stop mode, or the user switched apps mid-dictation: paste whatever was not typed live.
        let typed = liveTyper.typed
        let remainder = finalText.hasPrefix(typed) ? String(finalText.dropFirst(typed.count)) : finalText
        guard !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            floatingPanel?.hide()
            let result = finalText.isEmpty ? "SKIPPED" : "COMPLETE"
            finishInput(inputID, startedAt: startedAt, result: result, details: "output=nothing_to_paste, chars=\(finalText.count)")
            return
        }
        pasteController.paste(remainder, to: targetApp) { [weak self] ok in
            self?.floatingPanel?.hide()
            self?.finishInput(
                inputID,
                startedAt: startedAt,
                result: ok ? "COMPLETE" : "FAILED",
                details: "output=paste, paste=\(ok ? "ok" : "failed"), chars=\(remainder.count)"
            )
        }
    }

    private func cancelRecording() {
        guard recordingState == .preparing || recordingState == .recording else { return }

        let wasRecording = recordingState == .recording
        recordingState = .idle
        statusItem?.button?.image = StatusIcon.make(recording: false)
        floatingPanel?.hide()
        targetApp = nil
        engine.cancel()
        if targetIsFrontmost {
            liveTyper.erase()
        }
        liveTyper.reset()

        if configStore.config.microphone.mode == "on_demand" {
            audioRecorder.stop()
        } else {
            audioRecorder.discardRecording(clearPreRoll: true)
        }

        let inputID = activeInputID
        let inputStartedAt = activeInputStartedAt
        Logger.shared.log(wasRecording ? "\(inputLogPrefix(inputID))recording cancelled by Escape; ASR skipped" : "\(inputLogPrefix(inputID))recording warmup cancelled by Escape")
        finishInput(inputID, startedAt: inputStartedAt, result: "CANCELLED", details: "reason=escape")
        scheduleTimedMicrophoneRelease(reason: "recording_cancelled")
    }

    private func inputLogPrefix(_ inputID: Int?) -> String {
        guard let inputID else { return "" }
        return "Input #\(inputID): "
    }

    private func finishInput(_ inputID: Int?, startedAt: Date?, result: String, details: String) {
        guard let inputID else { return }
        let elapsedMs = startedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        Logger.shared.log("========== INPUT #\(inputID) \(result) elapsed_ms=\(elapsedMs) \(details) ==========")
        if activeInputID == inputID {
            activeInputID = nil
            activeInputStartedAt = nil
            targetApp = nil
            liveTargetPID = nil
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let engineTitle: String
        let name = engine.kind.shortName
        let isRemote = engine.kind.isRemote
        let remoteEndpoint = (engine as? RemoteWhisperEngine)?.endpoint ?? RemoteWhisperSettings.selectedEndpoint
        switch engineState {
        case .notLoaded: engineTitle = "\(name): not loaded"
        case .loading: engineTitle = isRemote ? "\(name): checking \(remoteEndpoint)…" : "\(name): loading…"
        case .ready: engineTitle = isRemote ? "\(name): ready (\(remoteEndpoint))" : "\(name): ready (local)"
        case .failed: engineTitle = isRemote ? "\(name): unreachable (\(remoteEndpoint))" : "\(name): model missing (see README)"
        }
        let engineItem = NSMenuItem(title: engineTitle, action: nil, keyEquivalent: "")
        engineItem.isEnabled = false
        menu.addItem(engineItem)

        // ASR Engine ▸ Local ▸ (ONNX models)  |  Remote ▸ (Whisper servers, Test connection)
        let engineMenu = NSMenu()
        let localMenu = NSMenu()
        let storedLocal = ASREngineKind.storedLocalModel
        for kind in ASREngineKind.localCases {
            let item = NSMenuItem(title: kind.title, action: #selector(selectEngine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            // Checkmark = model that Local uses (shown even while Remote is active).
            item.state = (isRemote ? storedLocal == kind : engine.kind == kind) ? .on : .off
            localMenu.addItem(item)
        }
        let localItem = NSMenuItem(title: "Local", action: nil, keyEquivalent: "")
        localItem.state = isRemote ? .off : .on
        localItem.submenu = localMenu
        engineMenu.addItem(localItem)

        let remoteMenu = NSMenu()
        let selectedRemote = RemoteWhisperSettings.selectedEndpoint
        if RemoteWhisperSettings.endpoints.isEmpty {
            let empty = NSMenuItem(title: "No Server Configured", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            remoteMenu.addItem(empty)
        }
        for endpoint in RemoteWhisperSettings.endpoints {
            let item = NSMenuItem(title: endpoint, action: #selector(selectRemoteEndpoint(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = endpoint
            item.state = isRemote && endpoint == selectedRemote ? .on : .off
            item.isEnabled = RemoteWhisperSettings.envEndpoint == nil || endpoint == RemoteWhisperSettings.envEndpoint
            let target = RemoteWhisperSettings.target(for: endpoint)
            item.toolTip = target.protocolKind == .openAITranscriptions
                ? "\(target.protocolKind.title) · \(target.model)"
                : target.protocolKind.title
            remoteMenu.addItem(item)
        }
        remoteMenu.addItem(.separator())
        let configureItem = NSMenuItem(title: "Configure…", action: #selector(openRemoteSettings), keyEquivalent: "")
        configureItem.target = self
        remoteMenu.addItem(configureItem)
        let testItem = NSMenuItem(title: "Test Connection", action: #selector(testRemoteConnection), keyEquivalent: "")
        testItem.target = self
        testItem.isEnabled = !RemoteWhisperSettings.endpoints.isEmpty
        remoteMenu.addItem(testItem)
        let remoteItem = NSMenuItem(title: "Remote", action: nil, keyEquivalent: "")
        remoteItem.state = isRemote ? .on : .off
        remoteItem.submenu = remoteMenu
        engineMenu.addItem(remoteItem)

        let engineMenuItem = NSMenuItem(title: "ASR Engine", action: nil, keyEquivalent: "")
        engineMenuItem.submenu = engineMenu
        menu.addItem(engineMenuItem)

        let openCCTitle = TranscriptFormatter.openCCPath == nil ? "OpenCC Not Installed" : "OpenCC Taiwan Phrases"
        let openCCItem = NSMenuItem(title: openCCTitle, action: #selector(toggleOpenCC), keyEquivalent: "")
        openCCItem.target = self
        openCCItem.state = TranscriptFormatter.useOpenCC && TranscriptFormatter.openCCPath != nil ? .on : .off
        openCCItem.isEnabled = TranscriptFormatter.openCCPath != nil
        menu.addItem(openCCItem)
        let numeralsItem = NSMenuItem(title: "Arabic Numerals", action: #selector(toggleArabicNumerals), keyEquivalent: "")
        numeralsItem.target = self
        numeralsItem.state = ChineseNumerals.enabled ? .on : .off
        menu.addItem(numeralsItem)
        let polishItem = NSMenuItem(title: "LLM Polish", action: #selector(toggleLLMPolish), keyEquivalent: "")
        polishItem.target = self
        polishItem.state = TextPolisher.enabled ? .on : .off
        menu.addItem(polishItem)
        menu.addItem(.separator())

        let liveItem = NSMenuItem(title: "Live Typing", action: #selector(toggleLiveTyping), keyEquivalent: "")
        liveItem.target = self
        liveItem.state = liveTypingActive ? .on : .off
        if isRemote {
            liveItem.isEnabled = false
            liveItem.toolTip = "Remote ASR pastes the text after recording stops."
        }
        menu.addItem(liveItem)
        menu.addItem(.separator())

        let moveLockItem = NSMenuItem(
            title: "Move Lock",
            action: #selector(toggleMoveLock(_:)),
            keyEquivalent: ""
        )
        moveLockItem.target = self
        moveLockItem.state = configStore.config.floatingDialog.moveLock ? .on : .off
        menu.addItem(moveLockItem)
        menu.addItem(.separator())

        let languageMenu = NSMenu()
        addLanguageItem(to: languageMenu, title: "Traditional Chinese", mode: "zh-tw")
        addLanguageItem(to: languageMenu, title: "Simplified Chinese", mode: "zh-cn")
        addLanguageItem(to: languageMenu, title: "English", mode: "en")
        addLanguageItem(to: languageMenu, title: "Auto Detect – Traditional", mode: "auto-tw")
        addLanguageItem(to: languageMenu, title: "Auto Detect – Simplified", mode: "auto-cn")
        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        let microphoneMenu = NSMenu()
        microphoneMenu.delegate = self
        microphoneDeviceMenu = microphoneMenu
        rebuildMicrophoneMenu(microphoneMenu)
        let microphoneItem = NSMenuItem(title: "Microphone Device", action: nil, keyEquivalent: "")
        microphoneItem.submenu = microphoneMenu
        menu.addItem(microphoneItem)

        let microphoneModeMenu = NSMenu()
        let timeoutMinutes = configStore.config.microphone.alwaysOnTimeoutMinutes
        let alwaysOnTitle = timeoutMinutes > 0
            ? "Always On – \(timeoutMinutes) min"
            : "Always On"
        addMicrophoneModeItem(to: microphoneModeMenu, title: alwaysOnTitle, mode: "always")
        addMicrophoneModeItem(to: microphoneModeMenu, title: "On Demand", mode: "on_demand")
        let microphoneModeItem = NSMenuItem(title: "Microphone Mode", action: nil, keyEquivalent: "")
        microphoneModeItem.submenu = microphoneModeMenu
        menu.addItem(microphoneModeItem)


        menu.addItem(.separator())
        let saveAllItem = NSMenuItem(
            title: "Save All to Obsidian",
            action: #selector(saveAllToObsidian),
            keyEquivalent: ""
        )
        saveAllItem.target = self
        menu.addItem(saveAllItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let reloadConfigItem = NSMenuItem(
            title: "Reload Config",
            action: #selector(reloadConfig),
            keyEquivalent: ""
        )
        reloadConfigItem.target = self
        menu.addItem(reloadConfigItem)
        let loginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        loginItem.target = self
        updateLaunchAtLoginItem(loginItem)
        menu.addItem(loginItem)
        launchAtLoginItem = loginItem
        menu.addItem(.separator())
        let relaunchItem = NSMenuItem(title: "Relaunch", action: #selector(relaunch), keyEquivalent: "")
        relaunchItem.target = self
        menu.addItem(relaunchItem)
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusMenu = menu
        statusItem?.menu = menu
    }

    private func addLanguageItem(to menu: NSMenu, title: String, mode: String) {
        let item = NSMenuItem(title: title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = mode
        item.state = configStore.config.chineseMode.mode == mode ? .on : .off
        menu.addItem(item)
    }

    @discardableResult
    private func rebuildMicrophoneMenu(_ menu: NSMenu) -> Int {
        menu.removeAllItems()
        let devices = AudioRecorder.inputDevices()
        refreshMicrophoneAvailability(devices: devices, reason: "microphone_menu")

        if devices.isEmpty {
            let item = NSMenuItem(title: "No microphones found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return 0
        }

        let defaultItem = NSMenuItem(
            title: "System Default",
            action: #selector(selectMicrophone(_:)),
            keyEquivalent: ""
        )
        defaultItem.target = self
        defaultItem.representedObject = ""
        defaultItem.state = configStore.config.microphone.selectedDeviceName.isEmpty ? .on : .off
        menu.addItem(defaultItem)
        menu.addItem(.separator())

        for (index, device) in devices.enumerated() {
            let deviceName = device.localizedName
            let item = NSMenuItem(
                title: "\(index + 1). \(device.localizedName)",
                action: #selector(selectMicrophone(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = deviceName
            item.state = configStore.config.microphone.selectedDeviceName == deviceName ? .on : .off
            menu.addItem(item)
        }
        return devices.count
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusMenu {
            // Login Item state can change outside the app (System Settings ▸ General ▸ Login Items).
            if let item = launchAtLoginItem { updateLaunchAtLoginItem(item) }
            return
        }
        guard menu === microphoneDeviceMenu else { return }
        let previousCount = max(0, menu.items.filter { !$0.isSeparatorItem }.count - 1)
        let currentCount = rebuildMicrophoneMenu(menu)
        Logger.shared.log(
            "Refreshed microphone menu: previous_device_count=\(previousCount), current_device_count=\(currentCount)"
        )
    }

    private func addMicrophoneModeItem(to menu: NSMenu, title: String, mode: String) {
        let item = NSMenuItem(title: title, action: #selector(selectMicrophoneMode(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = mode
        item.state = configStore.config.microphone.mode == mode ? .on : .off
        menu.addItem(item)
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = ASREngineKind(rawValue: raw), !kind.isRemote else { return }
        guard kind != engine.kind else { return }
        guard recordingState == .idle else {
            NSSound.beep()
            return
        }
        ASREngineKind.persistLocalModel(kind)
        ASREngineKind.persistBackend(remote: false)
        switchEngine(to: kind)
    }

    @objc private func selectRemoteEndpoint(_ sender: NSMenuItem) {
        guard let endpoint = sender.representedObject as? String else { return }
        guard recordingState == .idle else {
            NSSound.beep()
            return
        }
        RemoteWhisperSettings.select(endpoint)
        ASREngineKind.persistBackend(remote: true)
        switchEngine(to: .remoteWhisper, force: true)
    }

    @objc private func testRemoteConnection() {
        let endpoint = RemoteWhisperSettings.selectedEndpoint
        if engine.kind.isRemote {
            loadEngine() // refreshes the status line at the top of the menu
            return
        }
        RemoteWhisperEngine.checkHealth(target: RemoteWhisperSettings.target(for: endpoint)) { ok, detail in
            Logger.shared.log("Remote ASR test: endpoint=\(endpoint), ok=\(ok), detail=\(detail)")
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = ok ? "Remote ASR Reachable" : "Remote ASR Unreachable"
                alert.informativeText = "\(endpoint): \(detail)"
                alert.runModal()
            }
        }
    }

    private func switchEngine(to kind: ASREngineKind, force: Bool = false) {
        guard force || kind != engine.kind else { return }
        engine.cancel()
        configureRemoteSettings()
        engine = kind.makeEngine()
        Logger.shared.log("ASR engine switched to \(kind.rawValue)"
            + (kind.isRemote ? " endpoint=\(RemoteWhisperSettings.selectedEndpoint)" : ""))
        statusItem?.button?.toolTip = "AirType (\(kind.shortName))"
        loadEngine()
        rebuildMenu()
    }

    @objc private func toggleOpenCC() {
        UserDefaults.standard.set(!TranscriptFormatter.useOpenCC, forKey: TranscriptFormatter.openCCDefaultsKey)
        rebuildMenu()
    }

    @objc private func toggleArabicNumerals() {
        UserDefaults.standard.set(!ChineseNumerals.enabled, forKey: ChineseNumerals.defaultsKey)
        Logger.shared.log("Arabic numerals \(ChineseNumerals.enabled ? "on" : "off")")
        rebuildMenu()
    }

    @objc private func toggleLLMPolish() {
        UserDefaults.standard.set(!TextPolisher.enabled, forKey: TextPolisher.defaultsKey)
        Logger.shared.log("LLM polish \(TextPolisher.enabled ? "on" : "off")")
        rebuildMenu()
    }

    @objc private func toggleLiveTyping() {
        liveTypingEnabled.toggle()
        rebuildMenu()
    }

    @objc private func toggleMoveLock(_ sender: NSMenuItem) {
        configStore.updateMoveLock(!configStore.config.floatingDialog.moveLock)
        rebuildMenu()
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        configStore.updateChineseMode(mode)
        rebuildMenu()
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let deviceName = sender.representedObject as? String else { return }
        configStore.updateMicrophoneDeviceName(deviceName)
        applyMicrophoneRuntimeSettings(reason: "menu_microphone")
        rebuildMenu()
    }

    @objc private func selectMicrophoneMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        configStore.updateMicrophoneMode(mode)
        applyMicrophoneRuntimeSettings(reason: "menu_microphone_mode")
        rebuildMenu()
    }

    @objc private func reloadConfig() {
        do {
            try configStore.load()
            migrateLegacyMicrophoneSelection()
            applyMicrophoneRuntimeSettings(reason: "reload_config")
            floatingPanel?.applyConfig()
            configureRemoteSettings()
            if engine.kind.isRemote, remoteEngineIsStale {
                switchEngine(to: .remoteWhisper, force: true)
            } else if case .failed = engineState {
                loadEngine()
            }
            rebuildMenu()
            Logger.shared.log("Reloaded the complete config and reapplied runtime settings")
        } catch {
            Logger.shared.log("Could not reload config: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    /// True when the running Remote engine no longer matches the selected endpoint / protocol / model / key.
    private var remoteEngineIsStale: Bool {
        guard let remote = engine as? RemoteWhisperEngine else { return false }
        let selected = RemoteWhisperSettings.selectedEndpoint
        let target = RemoteWhisperSettings.target(for: selected)
        return remote.endpoint != selected
            || remote.target.protocolKind != target.protocolKind
            || remote.target.model != target.model
            || remote.target.apiKey != target.apiKey
    }

    @objc private func openSettings() {
        showSettings(tab: nil)
    }

    @objc private func openRemoteSettings() {
        showSettings(tab: SettingsWindowController.remoteTabID)
    }

    private func showSettings(tab: String?) {
        if settingsWindow == nil {
            let controller = SettingsWindowController(configPath: configStore.filePath)
            controller.onSave = { [weak self] newConfig, useRemote in
                self?.applySettings(newConfig, useRemote: useRemote)
            }
            settingsWindow = controller
        }
        settingsWindow?.present(
            config: configStore.config,
            remoteActive: engine.kind.isRemote,
            tab: tab
        )
    }

    /// Settings window → write config.toml, reload it, and reapply runtime settings without a restart.
    private func applySettings(_ newConfig: AirTypeConfig, useRemote: Bool) {
        configStore.replaceAndSave(newConfig)
        if let endpoint = RemoteWhisperSettings.normalize(newConfig.remoteASR.endpoint) {
            RemoteWhisperSettings.select(endpoint)
        }
        reloadConfig()
        guard recordingState == .idle else { return }
        if useRemote, !engine.kind.isRemote {
            ASREngineKind.persistBackend(remote: true)
            switchEngine(to: .remoteWhisper, force: true)
        } else if !useRemote, engine.kind.isRemote {
            ASREngineKind.persistBackend(remote: false)
            switchEngine(to: ASREngineKind.storedLocalModel, force: true)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Launch at Login (SMAppService.mainApp is the source of truth; no config mirror)

    private static func loginItemStatusName(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private func updateLaunchAtLoginItem(_ item: NSMenuItem) {
        switch SMAppService.mainApp.status {
        case .enabled: item.state = .on
        case .requiresApproval: item.state = .mixed
        default: item.state = .off
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        let before = service.status
        let enable = before != .enabled && before != .requiresApproval
        do {
            if enable {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            Logger.shared.log(
                "Launch at Login \(enable ? "register" : "unregister") failed: \(error.localizedDescription) "
                    + "status=\(Self.loginItemStatusName(service.status))"
            )
            showLaunchAtLoginAlert(
                message: "Could not \(enable ? "enable" : "disable") Launch at Login",
                info: error.localizedDescription,
                offerSettings: true
            )
            updateLaunchAtLoginItem(sender)
            return
        }
        let after = service.status
        Logger.shared.log(
            "Launch at Login \(enable ? "register" : "unregister"): "
                + "\(Self.loginItemStatusName(before)) -> \(Self.loginItemStatusName(after)) app=\(Bundle.main.bundleURL.path)"
        )
        updateLaunchAtLoginItem(sender)
        if after == .requiresApproval {
            showLaunchAtLoginAlert(
                message: "Allow AirTypeLocalApp in Login Items",
                info: "macOS needs your approval. In System Settings ▸ General ▸ Login Items, turn on AirTypeLocalApp.",
                offerSettings: true
            )
        }
    }

    private func showLaunchAtLoginAlert(message: String, info: String, offerSettings: Bool) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        if offerSettings {
            alert.addButton(withTitle: "Open Login Items")
            alert.addButton(withTitle: "Later")
        } else {
            alert.addButton(withTitle: "OK")
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, offerSettings {
            SMAppService.openSystemSettingsLoginItems()
        }
    }


    /// Pull unfinished Obsidian notes from the WebUI backend and write them into the local vault path.
    @objc private func saveAllToObsidian() {
        let endpoint = configStore.config.backend.selectedEndpoint
        let auth = configStore.config.webui.auth
        let obsidian = configStore.config.obsidian
        if obsidian.vaultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Obsidian Vault Path Missing"
            alert.informativeText = "Set Settings ▸ Obsidian ▸ Vault Path first (your vault folder on this Mac)."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                openSettings()
            }
            return
        }

        Logger.shared.log("Save all to Obsidian: endpoint=\(endpoint), vault=\(obsidian.vaultPath)")
        Task {
            let client = BackendClient()
            var saved = 0
            var failed = 0
            var skipped = 0
            var firstError: String?
            do {
                let summaries = try await client.listClipRequests(endpoint: endpoint, auth: auth)
                for summary in summaries {
                    let alreadySaved = (summary.obsidian_save ?? "") == "complete"
                    let ready = summary.status == "completed" && (summary.has_note ?? false) && !alreadySaved
                    guard ready else {
                        skipped += 1
                        continue
                    }
                    do {
                        let detail = try await client.fetchClipRequest(id: summary.id, endpoint: endpoint, auth: auth)
                        let note = (detail.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard detail.status == "completed", !note.isEmpty else {
                            skipped += 1
                            continue
                        }
                        let title = (detail.note_title?.isEmpty == false ? detail.note_title! : (detail.title ?? "Untitled"))
                        let path = try ObsidianVault.writeNote(title: title, note: note, config: obsidian)
                        try await client.markClipRequestSaved(id: summary.id, endpoint: endpoint, auth: auth)
                        saved += 1
                        Logger.shared.log("Saved to Obsidian: id=\(summary.id) path=\(path.path)")
                    } catch {
                        failed += 1
                        if firstError == nil { firstError = error.localizedDescription }
                        Logger.shared.log("Save to Obsidian failed: id=\(summary.id) error=\(error.localizedDescription)")
                    }
                }
            } catch {
                failed += 1
                firstError = error.localizedDescription
                Logger.shared.log("Save all to Obsidian list failed: \(error.localizedDescription)")
            }

            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = failed == 0 ? "Saved to Obsidian" : "Save to Obsidian Finished with Errors"
                var info = "Saved \(saved), failed \(failed), skipped \(skipped)."
                if let firstError, !firstError.isEmpty {
                    info += "\n\nFirst error: \(firstError)"
                }
                info += "\n\nVault: \(obsidian.vaultPath)"
                alert.informativeText = info
                alert.runModal()
            }
        }
    }

    /// Quit and start a fresh process so newly granted permissions (Accessibility, Input Monitoring) apply.
    @objc private func relaunch() {
        let bundlePath = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "relaunch",
            String(pid),
            bundlePath
        ]
        do {
            try helper.run()
        } catch {
            Logger.shared.log("Relaunch failed: \(error.localizedDescription)")
            return
        }
        Logger.shared.log("Relaunching \(bundlePath)")
        NSApp.terminate(nil)
    }
}
