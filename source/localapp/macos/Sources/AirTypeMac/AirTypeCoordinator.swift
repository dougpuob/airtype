import AppKit
import AVFoundation
import Foundation

private final class LLMModelMenuSelection: NSObject {
    let serverName: String
    let modelName: String

    init(serverName: String, modelName: String) {
        self.serverName = serverName
        self.modelName = modelName
    }
}

@MainActor
final class AirTypeCoordinator: NSObject, ObservableObject, NSMenuDelegate {
    private let configStore = ConfigStore()
    private let audioRecorder = AudioRecorder()
    private let pasteController = PasteController()
    private let backendClient = BackendClient()
    private let backendProcessManager = BackendProcessManager()
    private var statusItem: NSStatusItem?
    private weak var microphoneDeviceMenu: NSMenu?
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
        backendProcessManager.startIfNeeded(config: configStore.config, projectRoot: configStore.projectRoot)
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
        backendProcessManager.stop()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = StatusIcon.make(recording: false)
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "AirType"
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
        audioRecorder.start(
            microphoneDeviceName: config.microphone.selectedDeviceName,
            preRollSeconds: config.microphone.preRollSeconds,
            onLevel: { [weak self] level in
                Task { @MainActor in self?.floatingPanel?.setLevel(level) }
            }
        )
        Logger.shared.log("\(inputLogPrefix(inputID))recording capture active: microphone_mode=\(config.microphone.mode), pre_roll_seconds=\(config.microphone.preRollSeconds)")
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

        guard let wavData = audioRecorder.stopAndMakeWav() else {
            floatingPanel?.hide()
            Logger.shared.log("\(inputLogPrefix(inputID))recording skipped: no wav data")
            if configStore.config.microphone.mode == "on_demand" {
                audioRecorder.stop()
            }
            finishInput(inputID, startedAt: inputStartedAt, result: "SKIPPED", details: "reason=no_wav_data")
            return
        }

        if configStore.config.microphone.mode == "on_demand" {
            audioRecorder.stop()
        }

        let config = configStore.config
        let targetApp = targetApp
        floatingPanel?.showTranscribing()
        Logger.shared.log("\(inputLogPrefix(inputID))recording stopped; wav_bytes=\(wavData.count)")
        Logger.shared.log("\(inputLogPrefix(inputID))submitting ASR: endpoint=\(config.backend.selectedEndpoint), language=\(config.chineseMode.mode), wav_bytes=\(wavData.count)")
        Task {
            do {
                let text = try await backendClient.transcribeIME(
                    wavData: wavData,
                    endpoint: config.backend.selectedEndpoint,
                    language: config.chineseMode.mode,
                    auth: config.webui.auth,
                    inputID: inputID
                )
                await MainActor.run {
                    Logger.shared.log("\(self.inputLogPrefix(inputID))ASR completed; paste requested")
                    self.pasteController.paste(text, to: targetApp) { ok in
                        self.floatingPanel?.hide()
                        let result = ok ? "COMPLETE" : "FAILED"
                        let details = "paste=\(ok ? "ok" : "failed"), chars=\(text.count)"
                        self.finishInput(inputID, startedAt: inputStartedAt, result: result, details: details)
                    }
                }
            } catch {
                Logger.shared.log("\(self.inputLogPrefix(inputID))ASR failed: \(error)")
                await MainActor.run {
                    self.floatingPanel?.hide()
                    self.finishInput(inputID, startedAt: inputStartedAt, result: "FAILED", details: "reason=asr_failed")
                }
            }
        }
    }

    private func cancelRecording() {
        guard recordingState == .preparing || recordingState == .recording else { return }

        let wasRecording = recordingState == .recording
        recordingState = .idle
        statusItem?.button?.image = StatusIcon.make(recording: false)
        floatingPanel?.hide()
        targetApp = nil

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
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

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
        let languageItem = NSMenuItem(title: "Chinese Mode", action: nil, keyEquivalent: "")
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
            ? "Always On (\(timeoutMinutes) min)"
            : "Always On"
        addMicrophoneModeItem(to: microphoneModeMenu, title: alwaysOnTitle, mode: "always")
        addMicrophoneModeItem(to: microphoneModeMenu, title: "On Demand", mode: "on_demand")
        let microphoneModeItem = NSMenuItem(title: "Microphone Mode", action: nil, keyEquivalent: "")
        microphoneModeItem.submenu = microphoneModeMenu
        menu.addItem(microphoneModeItem)

        // The LLM Server menu is only relevant for the web UI and is not needed in the local app.
        // It has been removed to simplify the local menu.

        menu.addItem(.separator())
        let reloadConfigItem = NSMenuItem(
            title: "Reload Config",
            action: #selector(reloadConfig),
            keyEquivalent: ""
        )
        reloadConfigItem.target = self
        menu.addItem(reloadConfigItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

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

    private func rebuildLLMServerMenu(_ menu: NSMenu) {
        let servers = configStore.availableLLMServers()
        if servers.isEmpty {
            let item = NSMenuItem(title: "No LLM servers configured", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        var modelMenusByServer: [String: NSMenu] = [:]
        var loadingItemsByServer: [String: NSMenuItem] = [:]
        for server in servers {
            let displayName = server.name == server.provider ? server.name : "\(server.name) (\(server.provider))"
            let item = NSMenuItem(
                title: displayName,
                action: nil,
                keyEquivalent: ""
            )
            item.representedObject = server.name
            item.state = configStore.config.webui.selectedServerName == server.name ? .on : .off
            let modelMenu = NSMenu()
            if server.models.isEmpty {
                let loadingItem = NSMenuItem(title: "Loading models...", action: nil, keyEquivalent: "")
                loadingItem.isEnabled = false
                modelMenu.addItem(loadingItem)
                loadingItemsByServer[server.name] = loadingItem
            } else {
                for modelName in server.models {
                    addLLMModelItem(to: modelMenu, title: modelName, serverName: server.name, model: modelName)
                }
            }
            modelMenusByServer[server.name] = modelMenu
            item.submenu = modelMenu
            menu.addItem(item)
        }

        // Fetch models asynchronously from all configured servers
        let backendEndpoint = configStore.config.backend.selectedEndpoint
        Task {
            do {
                let models = try await backendClient.fetchAllLLMModels(endpoint: backendEndpoint, auth: configStore.config.webui.auth)
                await MainActor.run {
                    let modelsByServer = Dictionary(grouping: models) { model in
                        model.server ?? ""
                    }
                    let modelNamesByServer = modelsByServer.mapValues { serverModels in
                        serverModels.map(\.name)
                    }
                    configStore.updateLLMServerModels(modelNamesByServer)
                    for server in servers {
                        guard let modelMenu = modelMenusByServer[server.name] else { continue }
                        modelMenu.removeAllItems()
                        let serverModels = modelsByServer[server.name] ?? []
                        if serverModels.isEmpty {
                            let emptyItem = NSMenuItem(title: "No models found", action: nil, keyEquivalent: "")
                            emptyItem.isEnabled = false
                            modelMenu.addItem(emptyItem)
                        } else {
                            for model in serverModels {
                                addLLMModelItem(to: modelMenu, title: model.name, serverName: server.name, model: model.name)
                            }
                        }
                    }
                }
            } catch {
                Logger.shared.log("Failed to fetch LLM models: \(error)")
                await MainActor.run {
                    for server in servers {
                        guard let modelMenu = modelMenusByServer[server.name] else { continue }
                        if let loadingItem = loadingItemsByServer[server.name] {
                            modelMenu.removeItem(loadingItem)
                        }
                        let errorItem = NSMenuItem(title: "Failed to load models", action: nil, keyEquivalent: "")
                        errorItem.isEnabled = false
                        modelMenu.addItem(errorItem)
                    }
                }
            }
        }
    }

    private func addLLMModelItem(to menu: NSMenu, title: String, serverName: String, model: String) {
        let item = NSMenuItem(title: title, action: #selector(selectLLMModel(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = LLMModelMenuSelection(serverName: serverName, modelName: model)
        let currentModel = configStore.config.webui.selectedModelName.isEmpty
            ? configStore.config.webui.llm.selectedModel
            : configStore.config.webui.selectedModelName
        item.state = configStore.config.webui.selectedServerName == serverName && currentModel == model ? .on : .off
        menu.addItem(item)
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
        let previousBackendMode = configStore.config.backend.mode
        let previousBackendEndpoint = configStore.config.backend.selectedEndpoint

        do {
            try configStore.load()
            migrateLegacyMicrophoneSelection()

            let backendChanged = previousBackendMode != configStore.config.backend.mode
                || previousBackendEndpoint != configStore.config.backend.selectedEndpoint
            if backendChanged {
                backendProcessManager.stop()
            }
            backendProcessManager.startIfNeeded(
                config: configStore.config,
                projectRoot: configStore.projectRoot
            )

            applyMicrophoneRuntimeSettings(reason: "reload_config")
            floatingPanel?.applyConfig()
            rebuildMenu()
            Logger.shared.log(
                "Reloaded the complete config and reapplied runtime settings: "
                + "backend_changed=\(backendChanged)"
            )
        } catch {
            Logger.shared.log("Could not reload config: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    @objc private func selectLLMServer(_ sender: NSMenuItem) {
        guard let serverName = sender.representedObject as? String else { return }
        configStore.updateLLMServer(serverName)
        rebuildMenu()
    }

    @objc private func selectLLMModel(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? LLMModelMenuSelection else { return }
        configStore.updateLLMSelection(serverName: selection.serverName, modelName: selection.modelName)
        rebuildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
