import AppKit
import Foundation

/// Settings window: one tab per section of ~/.airtype-experiment/config.toml, plus the Remote ASR tab
/// ([localapp.remote-asr]) with endpoint / protocol / model discovery / test. Save writes config.toml
/// through ConfigStore and the coordinator reloads it in-app.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTabViewDelegate {
    static let remoteTabID = "localapp.remote-asr"
    static let llmTabID = "webui.llm-server"

    /// (new config, use Remote ASR as the active engine)
    var onSave: ((AirTypeConfig, Bool) -> Void)?

    private let configPath: String
    private var window: NSWindow?
    private let tabView = NSTabView()
    private var baseConfig = AirTypeConfig()

    private struct FieldBinding {
        let descriptor: ConfigFieldDescriptor
        let get: () -> String
        let set: (String) -> Void
    }
    private var sectionBindings: [FieldBinding] = []

    // LLM servers ([[webui.llm-server]] + [webui] default-llm-server-name)
    private var llmBindings: [FieldBinding] = []
    private var llmServers: [LLMServerConfig] = []
    private var llmIndex = 0
    private let llmServerPopup = NSPopUpButton()
    private let llmDefaultPopup = NSPopUpButton()

    // Remote ASR
    private let remoteEndpointField = NSTextField()
    private let remoteProtocolPopup = NSPopUpButton()
    private let remoteAPIKeyField = NSSecureTextField()
    private let remoteModelCombo = NSComboBox()
    private let remoteFetchButton = NSButton()
    private let remoteFetchNote = NSTextField(wrappingLabelWithString: "")
    private let remoteUseCheckbox = NSButton(checkboxWithTitle: "Use Remote ASR", target: nil, action: nil)
    private let remoteTestButton = NSButton()
    private let remoteSpinner = NSProgressIndicator()
    private let remoteTestResult = NSTextField(wrappingLabelWithString: "")
    private let footerStatus = NSTextField(labelWithString: "")

    init(configPath: String) {
        self.configPath = configPath
        super.init()
    }

    // MARK: - Presenting

    func present(config: AirTypeConfig, remoteActive: Bool, tab: String?) {
        if window == nil {
            buildWindow()
        }
        guard let window else { return }
        if !window.isVisible {
            load(config: config, remoteActive: remoteActive)
            window.center()
        }
        if let tab, let index = tabView.tabViewItems.firstIndex(where: { ($0.identifier as? String) == tab }) {
            tabView.selectTabViewItem(at: index)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func load(config: AirTypeConfig, remoteActive: Bool) {
        baseConfig = config
        for binding in sectionBindings {
            binding.set(ConfigStore.displayValue(section: binding.descriptor.section, key: binding.descriptor.key, in: config))
        }
        llmServers = config.webui.llmServers.isEmpty ? [config.webui.llm] : config.webui.llmServers
        llmIndex = max(0, llmServers.firstIndex(where: { $0.name == config.webui.selectedServerName }) ?? 0)
        refreshLLMPopups(defaultName: config.webui.selectedServerName)
        loadLLMFields()

        remoteEndpointField.stringValue = config.remoteASR.endpoint.isEmpty ? config.backend.remoteEndpoint : config.remoteASR.endpoint
        selectProtocol(RemoteASRProtocol(rawValue: config.remoteASR.protocolName) ?? .webuiIME)
        remoteAPIKeyField.stringValue = config.remoteASR.apiKey
        remoteModelCombo.removeAllItems()
        remoteModelCombo.stringValue = config.remoteASR.model
        remoteFetchNote.stringValue = "Fetch Models reads /v1/models (OpenAI compatible) or the AirType WebUI status."
        remoteUseCheckbox.state = remoteActive ? .on : .off
        remoteTestResult.stringValue = ""
        footerStatus.stringValue = ""
    }

    // MARK: - Window

    private func buildWindow() {
        let window = EditableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AirType Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 480)
        window.delegate = self

        tabView.translatesAutoresizingMaskIntoConstraints = false
        let descriptors = ConfigStore.sectionDescriptors
        for section in descriptors {
            switch section.name {
            case Self.remoteTabID:
                addTab(id: section.name, title: "Remote ASR", content: buildRemoteTab(section))
                continue
            case Self.llmTabID, "webui":
                continue
            default:
                addTab(id: section.name, title: Self.tabTitle(section.name), content: buildSectionTab(section))
            }
        }
        if let llm = descriptors.first(where: { $0.name == Self.llmTabID }) {
            addTab(id: Self.llmTabID, title: "LLM Servers", content: buildLLMTab(llm))
        }

        let pathLabel = NSTextField(labelWithString: (configPath as NSString).abbreviatingWithTildeInPath)
        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        footerStatus.font = .systemFont(ofSize: 11)
        footerStatus.textColor = .secondaryLabelColor
        let openButton = NSButton(title: "Open File", target: self, action: #selector(openConfigFile))
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        let applyButton = NSButton(title: "Apply", target: self, action: #selector(apply))
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        let leftStack = NSStackView(views: [pathLabel, footerStatus])
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 2
        let footer = NSStackView(views: [leftStack, NSView(), openButton, cancelButton, applyButton, saveButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        leftStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let content = NSView()
        content.addSubview(tabView)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            footer.topAnchor.constraint(equalTo: tabView.bottomAnchor, constant: 10),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
        window.contentView = content
        self.window = window
    }

    private func addTab(id: String, title: String, content: NSView) {
        let item = NSTabViewItem(identifier: id)
        item.label = title
        item.view = content
        tabView.addTabViewItem(item)
    }

    private static func tabTitle(_ section: String) -> String {
        switch section {
        case "localapp.chinese-mode": return "Language"
        case "localapp.backend-endpoint": return "Backend"
        case "localapp.microphone": return "Microphone"
        case "localapp.floating-dialog": return "Floating Dialog"
        case "localapp.obsidian": return "Obsidian"
        case "webui.auth": return "Web UI Auth"
        case "webui.whisper-server": return "Whisper Server"
        default: return section
        }
    }

    private static func fieldLabel(_ key: String) -> String {
        switch key {
        case "vault_path": return "Vault Path"
        case "default_folder": return "Default Folder"
        case "api_key": return "API Key"
        case "contextLength": return "Context Length"
        case "selected-model": return "Selected Model"
        case "default-llm-server-name": return "Default Server"
        default:
            return key.split(whereSeparator: { $0 == "_" || $0 == "-" })
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    // MARK: - Generic section tabs

    private func buildSectionTab(_ section: ConfigSectionDescriptor) -> NSView {
        var rows: [NSView] = [sectionHeader("[\(section.name)]")]
        for field in section.fields {
            let (control, binding) = makeControl(field)
            sectionBindings.append(binding)
            rows.append(row(label: Self.fieldLabel(field.key), key: field.key, control: control, comment: field.comment))
        }
        return scrollWrap(rows)
    }

    private func makeControl(_ field: ConfigFieldDescriptor) -> (NSView, FieldBinding) {
        if field.kind == .bool {
            let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            return (box, FieldBinding(descriptor: field,
                                      get: { box.state == .on ? "true" : "false" },
                                      set: { box.state = ["true", "1", "yes", "on"].contains($0.lowercased()) ? .on : .off }))
        }
        if !field.options.isEmpty {
            let popup = NSPopUpButton()
            popup.addItems(withTitles: field.options)
            return (popup, FieldBinding(descriptor: field,
                                        get: { popup.titleOfSelectedItem ?? "" },
                                        set: { value in
                                            if popup.item(withTitle: value) == nil, !value.isEmpty { popup.addItem(withTitle: value) }
                                            popup.selectItem(withTitle: value)
                                        }))
        }
        let text: NSTextField = field.kind == .secret ? NSSecureTextField() : NSTextField()
        text.widthAnchor.constraint(equalToConstant: 480).isActive = true
        if field.key == "system" {
            text.usesSingleLineMode = false
            text.cell?.wraps = true
            text.cell?.isScrollable = false
            text.heightAnchor.constraint(equalToConstant: 88).isActive = true
        }
        if field.kind == .array { text.placeholderString = "Comma-separated" }
        return (text, FieldBinding(descriptor: field, get: { text.stringValue }, set: { text.stringValue = $0 }))
    }

    private func sectionHeader(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func row(label: String, key: String?, control: NSView, comment: String?) -> NSView {
        let name = NSTextField(labelWithString: label)
        name.alignment = .right
        name.toolTip = key
        name.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let right = NSStackView(views: [control])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 3
        if let comment, !comment.isEmpty {
            let note = NSTextField(wrappingLabelWithString: comment)
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            note.preferredMaxLayoutWidth = 480
            right.addArrangedSubview(note)
        }
        let stack = NSStackView(views: [name, right])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 12
        return stack
    }

    private func scrollWrap(_ rows: [NSView]) -> NSView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = document
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        return scroll
    }

    // MARK: - LLM servers tab

    private func buildLLMTab(_ section: ConfigSectionDescriptor) -> NSView {
        llmServerPopup.target = self
        llmServerPopup.action = #selector(llmServerChanged)
        let addButton = NSButton(title: "Add", target: self, action: #selector(addLLMServer))
        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeLLMServer))
        let serverRow = NSStackView(views: [llmServerPopup, addButton, removeButton])
        serverRow.spacing = 8
        var rows: [NSView] = [
            sectionHeader("[webui] default-llm-server-name"),
            row(label: "Default Server", key: "default-llm-server-name", control: llmDefaultPopup,
                comment: "Server used for LLM Polish and the Web UI."),
            sectionHeader("[[webui.llm-server]]"),
            row(label: "Server", key: nil, control: serverRow, comment: nil)
        ]
        for field in section.fields {
            let (control, binding) = makeControl(field)
            llmBindings.append(binding)
            rows.append(row(label: Self.fieldLabel(field.key), key: field.key, control: control, comment: field.comment))
        }
        return scrollWrap(rows)
    }

    private func refreshLLMPopups(defaultName: String?) {
        let names = llmServers.map(\.name)
        let previousDefault = defaultName ?? llmDefaultPopup.titleOfSelectedItem
        llmServerPopup.removeAllItems()
        llmServerPopup.addItems(withTitles: names.enumerated().map { "\($0.offset + 1). \($0.element)" })
        if !names.isEmpty { llmServerPopup.selectItem(at: min(llmIndex, names.count - 1)) }
        llmDefaultPopup.removeAllItems()
        llmDefaultPopup.addItems(withTitles: names)
        if let previousDefault, names.contains(previousDefault) {
            llmDefaultPopup.selectItem(withTitle: previousDefault)
        }
    }

    private func loadLLMFields() {
        guard llmServers.indices.contains(llmIndex) else { return }
        var config = baseConfig
        config.webui.llm = llmServers[llmIndex]
        for binding in llmBindings {
            binding.set(ConfigStore.displayValue(section: binding.descriptor.section, key: binding.descriptor.key, in: config))
        }
    }

    private func commitLLMFields() {
        guard llmServers.indices.contains(llmIndex) else { return }
        var config = baseConfig
        config.webui.llm = llmServers[llmIndex]
        for binding in llmBindings {
            ConfigStore.apply(section: binding.descriptor.section, key: binding.descriptor.key, value: binding.get(), to: &config)
        }
        let oldName = llmServers[llmIndex].name
        llmServers[llmIndex] = config.webui.llm
        let defaultName = llmDefaultPopup.titleOfSelectedItem == oldName ? config.webui.llm.name : llmDefaultPopup.titleOfSelectedItem
        refreshLLMPopups(defaultName: defaultName)
    }

    @objc private func llmServerChanged() {
        let newIndex = llmServerPopup.indexOfSelectedItem
        commitLLMFields()
        llmIndex = max(0, newIndex)
        llmServerPopup.selectItem(at: llmIndex)
        loadLLMFields()
    }

    @objc private func addLLMServer() {
        commitLLMFields()
        var name = "server"
        var suffix = 2
        while llmServers.contains(where: { $0.name == name }) { name = "server-\(suffix)"; suffix += 1 }
        llmServers.append(LLMServerConfig(name: name, provider: "openai"))
        llmIndex = llmServers.count - 1
        refreshLLMPopups(defaultName: nil)
        loadLLMFields()
    }

    @objc private func removeLLMServer() {
        guard llmServers.count > 1 else { NSSound.beep(); return }
        llmServers.remove(at: llmIndex)
        llmIndex = max(0, llmIndex - 1)
        refreshLLMPopups(defaultName: nil)
        loadLLMFields()
    }

    // MARK: - Remote ASR tab

    private func buildRemoteTab(_ section: ConfigSectionDescriptor) -> NSView {
        remoteEndpointField.placeholderString = "https://host or http://host:port"
        remoteEndpointField.widthAnchor.constraint(equalToConstant: 480).isActive = true
        for kind in RemoteASRProtocol.allCases {
            remoteProtocolPopup.addItem(withTitle: kind.title)
            remoteProtocolPopup.lastItem?.representedObject = kind.rawValue
        }
        remoteAPIKeyField.placeholderString = "Bearer token (OpenAI Compatible only)"
        remoteAPIKeyField.widthAnchor.constraint(equalToConstant: 480).isActive = true
        remoteModelCombo.completes = true
        remoteModelCombo.numberOfVisibleItems = 14
        remoteModelCombo.widthAnchor.constraint(equalToConstant: 360).isActive = true
        remoteFetchButton.title = "Fetch Models"
        remoteFetchButton.bezelStyle = .rounded
        remoteFetchButton.target = self
        remoteFetchButton.action = #selector(fetchRemoteModels)
        let modelRow = NSStackView(views: [remoteModelCombo, remoteFetchButton])
        modelRow.spacing = 8
        remoteFetchNote.font = .systemFont(ofSize: 11)
        remoteFetchNote.textColor = .secondaryLabelColor
        remoteFetchNote.preferredMaxLayoutWidth = 480
        let modelStack = NSStackView(views: [modelRow, remoteFetchNote])
        modelStack.orientation = .vertical
        modelStack.alignment = .leading
        modelStack.spacing = 4

        remoteTestButton.title = "Test"
        remoteTestButton.bezelStyle = .rounded
        remoteTestButton.target = self
        remoteTestButton.action = #selector(testRemote)
        remoteSpinner.style = .spinning
        remoteSpinner.controlSize = .small
        remoteSpinner.isDisplayedWhenStopped = false
        let testRow = NSStackView(views: [remoteTestButton, remoteSpinner])
        testRow.spacing = 8
        remoteTestResult.isSelectable = true
        remoteTestResult.preferredMaxLayoutWidth = 480
        let testStack = NSStackView(views: [testRow, remoteTestResult])
        testStack.orientation = .vertical
        testStack.alignment = .leading
        testStack.spacing = 6

        let comment = { (key: String) in section.fields.first(where: { $0.key == key })?.comment }
        let rows: [NSView] = [
            sectionHeader("[\(section.name)]"),
            row(label: "Endpoint", key: "endpoint", control: remoteEndpointField, comment: comment("endpoint")),
            row(label: "Protocol", key: "protocol", control: remoteProtocolPopup,
                comment: "AirType WebUI: POST /api/transcribe/ime with [webui.auth]. OpenAI Compatible: POST /v1/audio/transcriptions (e.g. oMLX)."),
            row(label: "API Key", key: "api_key", control: remoteAPIKeyField, comment: comment("api_key")),
            row(label: "Model", key: "model", control: modelStack, comment: nil),
            row(label: "Engine", key: nil, control: remoteUseCheckbox,
                comment: "Remote ASR has no live text; it pastes after recording stops."),
            row(label: "Test", key: nil, control: testStack,
                comment: "Checks the server, then transcribes a short spoken sample generated with macOS say.")
        ]
        return scrollWrap(rows)
    }

    private func selectProtocol(_ kind: RemoteASRProtocol) {
        if let index = remoteProtocolPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == kind.rawValue }) {
            remoteProtocolPopup.selectItem(at: index)
        }
    }

    private var selectedProtocol: RemoteASRProtocol {
        RemoteASRProtocol(rawValue: remoteProtocolPopup.selectedItem?.representedObject as? String ?? "") ?? .webuiIME
    }

    private func currentRemoteTarget() -> RemoteASRTarget? {
        guard let endpoint = RemoteWhisperSettings.normalize(remoteEndpointField.stringValue) else { return nil }
        return RemoteASRTarget(
            endpoint: endpoint,
            protocolKind: selectedProtocol,
            model: remoteModelCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: remoteAPIKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            auth: collectConfig().webui.auth
        )
    }

    @objc private func fetchRemoteModels() {
        guard let target = currentRemoteTarget() else {
            remoteFetchNote.stringValue = "Enter an endpoint first."
            return
        }
        remoteFetchButton.isEnabled = false
        remoteFetchNote.stringValue = "Fetching models from \(target.endpoint)…"
        Task { @MainActor in
            let list = await BackendClient().listRemoteModels(target: target)
            remoteFetchButton.isEnabled = true
            let sorted = Self.sortASRFirst(list.models)
            remoteModelCombo.removeAllItems()
            remoteModelCombo.addItems(withObjectValues: sorted)
            if let detected = list.detectedProtocol {
                selectProtocol(detected)
            }
            let current = remoteModelCombo.stringValue
            if current.isEmpty || !sorted.contains(current), let first = sorted.first(where: Self.looksLikeASR) ?? sorted.first {
                remoteModelCombo.stringValue = first
            }
            remoteFetchNote.stringValue = list.note
            Logger.shared.log("Settings: fetched remote models endpoint=\(target.endpoint), count=\(list.models.count), protocol=\(list.detectedProtocol?.rawValue ?? "none")")
        }
    }

    private static func looksLikeASR(_ id: String) -> Bool {
        let lowered = id.lowercased()
        return ["asr", "whisper", "voice", "sensevoice", "paraformer", "parakeet", "speech", "stt"].contains { lowered.contains($0) }
    }

    private static func sortASRFirst(_ ids: [String]) -> [String] {
        ids.filter(looksLikeASR) + ids.filter { !looksLikeASR($0) }
    }

    @objc private func testRemote() {
        guard let target = currentRemoteTarget() else {
            showTestResult("Enter an endpoint first.", ok: false)
            return
        }
        if target.protocolKind == .openAITranscriptions, target.model.isEmpty {
            showTestResult("Choose a model first (Fetch Models).", ok: false)
            return
        }
        remoteTestButton.isEnabled = false
        remoteSpinner.startAnimation(nil)
        showTestResult("Testing \(target.endpoint)…", ok: nil)
        let mode = collectConfig().chineseMode.mode
        Task { @MainActor in
            var lines: [String] = []
            let health: (Bool, String) = await withCheckedContinuation { continuation in
                RemoteWhisperEngine.checkHealth(target: target) { ok, detail in continuation.resume(returning: (ok, detail)) }
            }
            lines.append((health.0 ? "✓ Server OK – " : "✗ Server check failed – ") + health.1)
            var ok = health.0
            if ok {
                let sample = "今天天氣很好，我們來測試語音辨識。"
                if let wav = await Self.makeSpokenSample(sample) {
                    let started = Date()
                    do {
                        let text = try await BackendClient().transcribe(
                            wavData: wav, target: target,
                            webuiLanguage: RemoteWhisperSettings.webuiLanguage(forMode: mode),
                            openAILanguage: RemoteWhisperSettings.openAILanguage(forMode: mode)
                        )
                        let seconds = String(format: "%.2f", Date().timeIntervalSince(started))
                        lines.append("✓ Transcribed in \(seconds) s: “\(text)”")
                        lines.append("Sample: “\(sample)”")
                    } catch {
                        ok = false
                        lines.append("✗ Transcription failed – \(error.localizedDescription)")
                    }
                } else {
                    lines.append("– Skipped transcription: could not generate a sample with /usr/bin/say.")
                }
            }
            Logger.shared.log("Settings: remote test endpoint=\(target.endpoint), protocol=\(target.protocolKind.rawValue), model=\(target.model), ok=\(ok), result=\(lines.joined(separator: " | "))")
            remoteSpinner.stopAnimation(nil)
            remoteTestButton.isEnabled = true
            showTestResult(lines.joined(separator: "\n"), ok: ok)
        }
    }

    private func showTestResult(_ text: String, ok: Bool?) {
        remoteTestResult.stringValue = text
        switch ok {
        case .some(true): remoteTestResult.textColor = .systemGreen
        case .some(false): remoteTestResult.textColor = .systemRed
        case .none: remoteTestResult.textColor = .secondaryLabelColor
        }
    }

    /// 16 kHz mono 16-bit WAV of `text` spoken by macOS `say` (Meijia zh_TW, falls back to the default voice).
    private static func makeSpokenSample(_ text: String) async -> Data? {
        await Task.detached {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("airtype-remote-test-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            for voice in ["Meijia", nil] as [String?] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                var arguments = ["-o", url.path, "--data-format=LEI16@16000"]
                if let voice { arguments += ["-v", voice] }
                process.arguments = arguments + [text]
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continue
                }
                if process.terminationStatus == 0, let data = try? Data(contentsOf: url), data.count > 44 {
                    return data
                }
            }
            return nil
        }.value
    }

    // MARK: - Save

    private func collectConfig() -> AirTypeConfig {
        var config = baseConfig
        for binding in sectionBindings {
            ConfigStore.apply(section: binding.descriptor.section, key: binding.descriptor.key, value: binding.get(), to: &config)
        }
        // LLM servers (read fields of the visible server without mutating the working list).
        var servers = llmServers
        if servers.indices.contains(llmIndex) {
            var scratch = config
            scratch.webui.llm = servers[llmIndex]
            for binding in llmBindings {
                ConfigStore.apply(section: binding.descriptor.section, key: binding.descriptor.key, value: binding.get(), to: &scratch)
            }
            servers[llmIndex] = scratch.webui.llm
        }
        if !servers.isEmpty {
            var defaultName = llmDefaultPopup.titleOfSelectedItem ?? servers[0].name
            if servers.indices.contains(llmIndex), defaultName == llmServers[llmIndex].name {
                defaultName = servers[llmIndex].name
            }
            let active = servers.first(where: { $0.name == defaultName }) ?? servers[0]
            config.webui.llmServers = servers
            config.webui.selectedServerName = active.name
            config.webui.llm = active
            config.webui.selectedModelName = active.selectedModel
        }
        config.remoteASR.endpoint = RemoteWhisperSettings.normalize(remoteEndpointField.stringValue) ?? ""
        config.remoteASR.protocolName = selectedProtocol.rawValue
        config.remoteASR.model = remoteModelCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.remoteASR.apiKey = remoteAPIKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return config
    }

    @discardableResult
    private func commit() -> Bool {
        let config = collectConfig()
        if remoteUseCheckbox.state == .on, config.remoteASR.endpoint.isEmpty {
            tabView.selectTabViewItem(withIdentifier: Self.remoteTabID)
            showTestResult("Enter a Remote ASR endpoint, or turn off Use Remote ASR.", ok: false)
            NSSound.beep()
            return false
        }
        if remoteUseCheckbox.state == .on, config.remoteASR.protocolName == RemoteASRProtocol.openAITranscriptions.rawValue,
           config.remoteASR.model.isEmpty {
            tabView.selectTabViewItem(withIdentifier: Self.remoteTabID)
            showTestResult("OpenAI Compatible needs a model.", ok: false)
            NSSound.beep()
            return false
        }
        baseConfig = config
        onSave?(config, remoteUseCheckbox.state == .on)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        footerStatus.stringValue = "Saved \(formatter.string(from: Date()))"
        return true
    }

    @objc private func apply() {
        commit()
    }

    @objc private func save() {
        if commit() {
            window?.close()
        }
    }

    @objc private func cancel() {
        window?.close()
    }

    @objc private func openConfigFile() {
        NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
    }
}

/// Top-left origin so scrolled forms start at the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The app is an accessory (no main menu), so route the standard editing shortcuts manually.
private final class EditableWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command || flags == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased() {
            let action: Selector?
            switch (key, flags.contains(.shift)) {
            case ("x", false): action = #selector(NSText.cut(_:))
            case ("c", false): action = #selector(NSText.copy(_:))
            case ("v", false): action = #selector(NSText.paste(_:))
            case ("a", false): action = #selector(NSText.selectAll(_:))
            case ("z", false): action = Selector(("undo:"))
            case ("z", true): action = Selector(("redo:"))
            case ("w", false):
                close()
                return true
            default: action = nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
