import AppKit
import Foundation

@MainActor
final class AirTypeCoordinator: ObservableObject {
    private let configStore = ConfigStore()
    private let audioRecorder = AudioRecorder()
    private let pasteController = PasteController()
    private let backendClient = BackendClient()
    private let backendProcessManager = BackendProcessManager()
    private var statusItem: NSStatusItem?
    private var hotkeyMonitor: HotkeyMonitor?
    private var floatingPanel: FloatingPanelController?
    private var targetApp: RunningAppIdentity?
    private enum RecordingState {
        case idle
        case preparing
        case recording
    }
    private var recordingState: RecordingState = .idle

    func start() {
        configStore.load()
        backendProcessManager.startIfNeeded(config: configStore.config, projectRoot: configStore.projectRoot)
        if configStore.config.microphone.mode == "always" {
            audioRecorder.prepare(
                microphoneOrder: configStore.config.microphone.selectedOrder,
                preRollSeconds: configStore.config.microphone.preRollSeconds
            )
        }
        setupStatusItem()
        setupFloatingPanel()
        setupHotkey()
    }

    func stop() {
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
        hotkeyMonitor = HotkeyMonitor(trigger: configStore.config.hotkey.trigger) {
            Task { @MainActor in
                self.toggleRecording()
            }
        }
        hotkeyMonitor?.start()
    }

    private func applyMicrophoneRuntimeSettings(reason: String) {
        let config = configStore.config
        Logger.shared.log(
            "Applying microphone settings: reason=\(reason), mode=\(config.microphone.mode), "
            + "selected_order=\(config.microphone.selectedOrder.isEmpty ? "default" : config.microphone.selectedOrder), "
            + "pre_roll_seconds=\(config.microphone.preRollSeconds)"
        )

        if recordingState == .preparing || recordingState == .recording {
            Logger.shared.log("Recording is active while microphone settings changed; stopping current recording before applying settings")
            stopRecording()
        }

        audioRecorder.stop()
        if config.microphone.mode == "always" {
            audioRecorder.prepare(
                microphoneOrder: config.microphone.selectedOrder,
                preRollSeconds: config.microphone.preRollSeconds
            )
        }
    }

    private func toggleRecording() {
        if recordingState == .recording || recordingState == .preparing {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        Logger.shared.log("Recording started")
        targetApp = RunningAppIdentity.frontmost()
        recordingState = .preparing
        statusItem?.button?.image = StatusIcon.make(recording: true)
        floatingPanel?.showPreparing()

        let config = configStore.config
        let warmupDelay: TimeInterval = config.microphone.mode == "always" ? 0 : 0.7
        if config.microphone.mode == "on_demand" {
            audioRecorder.prepare(
                microphoneOrder: config.microphone.selectedOrder,
                preRollSeconds: config.microphone.preRollSeconds
            )
            Logger.shared.log("On-demand microphone warmup started: delay_ms=\(Int(warmupDelay * 1000))")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + warmupDelay) { [weak self] in
            self?.beginRecordingIfStillPreparing()
        }
    }

    private func beginRecordingIfStillPreparing() {
        guard recordingState == .preparing else { return }
        let config = configStore.config
        recordingState = .recording
        floatingPanel?.showRecording()
        audioRecorder.start(
            microphoneOrder: config.microphone.selectedOrder,
            preRollSeconds: config.microphone.preRollSeconds,
            onLevel: { [weak self] level in
                Task { @MainActor in self?.floatingPanel?.setLevel(level) }
            }
        )
        Logger.shared.log("Recording capture active: microphone_mode=\(config.microphone.mode), pre_roll_seconds=\(config.microphone.preRollSeconds)")
    }

    private func stopRecording() {
        Logger.shared.log("Recording stopped")
        let wasRecording = recordingState == .recording
        recordingState = .idle
        statusItem?.button?.image = StatusIcon.make(recording: false)
        floatingPanel?.hide()

        if !wasRecording {
            if configStore.config.microphone.mode == "on_demand" {
                audioRecorder.stop()
            }
            Logger.shared.log("Recording cancelled before capture became active")
            return
        }

        guard let wavData = audioRecorder.stopAndMakeWav() else {
            Logger.shared.log("Recording skipped: no wav data")
            if configStore.config.microphone.mode == "on_demand" {
                audioRecorder.stop()
            }
            return
        }

        if configStore.config.microphone.mode == "on_demand" {
            audioRecorder.stop()
        }

        let config = configStore.config
        Logger.shared.log("Submitting ASR: endpoint=\(config.backend.selectedEndpoint), language=\(config.chineseMode.mode), wav_bytes=\(wavData.count)")
        Task {
            do {
                let text = try await backendClient.transcribeIME(
                    wavData: wavData,
                    endpoint: config.backend.selectedEndpoint,
                    language: config.chineseMode.mode
                )
                await MainActor.run {
                    self.pasteController.paste(text, to: self.targetApp)
                }
            } catch {
                Logger.shared.log("ASR failed: \(error)")
            }
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
        rebuildMicrophoneMenu(microphoneMenu)
        let microphoneItem = NSMenuItem(title: "Microphone Device", action: nil, keyEquivalent: "")
        microphoneItem.submenu = microphoneMenu
        menu.addItem(microphoneItem)

        let microphoneModeMenu = NSMenu()
        addMicrophoneModeItem(to: microphoneModeMenu, title: "On Demand", mode: "on_demand")
        addMicrophoneModeItem(to: microphoneModeMenu, title: "Always Warm", mode: "always")
        let microphoneModeItem = NSMenuItem(title: "Microphone Mode", action: nil, keyEquivalent: "")
        microphoneModeItem.submenu = microphoneModeMenu
        menu.addItem(microphoneModeItem)

        let hotkeyMenu = NSMenu()
        addHotkeyItem(to: hotkeyMenu, title: "Right Ctrl x2", trigger: .rightControl)
        addHotkeyItem(to: hotkeyMenu, title: "Right Option x2", trigger: .rightOption)
        let hotkeyItem = NSMenuItem(title: "Hotkey", action: nil, keyEquivalent: "")
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)

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

    private func rebuildMicrophoneMenu(_ menu: NSMenu) {
        let devices = AudioRecorder.inputDevices()
        if devices.isEmpty {
            let item = NSMenuItem(title: "No microphones found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        for (index, device) in devices.enumerated() {
            let order = String(index + 1)
            let item = NSMenuItem(
                title: "\(index + 1). \(device.localizedName)",
                action: #selector(selectMicrophone(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = order
            item.state = configStore.config.microphone.selectedOrder == order ? .on : .off
            menu.addItem(item)
        }
    }

    private func addMicrophoneModeItem(to menu: NSMenu, title: String, mode: String) {
        let item = NSMenuItem(title: title, action: #selector(selectMicrophoneMode(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = mode
        item.state = configStore.config.microphone.mode == mode ? .on : .off
        menu.addItem(item)
    }

    private func addHotkeyItem(to menu: NSMenu, title: String, trigger: HotkeyKey) {
        let item = NSMenuItem(title: title, action: #selector(selectHotkey(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = trigger.rawValue
        item.state = configStore.config.hotkey.trigger == trigger ? .on : .off
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
        guard let order = sender.representedObject as? String else { return }
        configStore.updateMicrophone(order)
        applyMicrophoneRuntimeSettings(reason: "menu_microphone")
        rebuildMenu()
    }

    @objc private func selectMicrophoneMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        configStore.updateMicrophoneMode(mode)
        applyMicrophoneRuntimeSettings(reason: "menu_microphone_mode")
        rebuildMenu()
    }

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        guard let rawTrigger = sender.representedObject as? String else { return }
        let trigger = HotkeyKey(configValue: rawTrigger)
        configStore.updateHotkeyTrigger(trigger)
        hotkeyMonitor?.updateTrigger(trigger)
        rebuildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
