import AVFoundation
import AppKit
import Foundation

/// Settings window: left sidebar (Service Providers / Endpoint Profiles / Voice Input / Others / Obsidian)
/// with a detail pane on the right. Leaves map to sections of ~/.airtype/config.json; Apply / Save writes
/// JSON through ConfigStore and the coordinator reloads it in-app.
///
/// Endpoints (ASR, Whisper, LLM) are named profile lists: [[localapp.remote-asr]], [[webui.whisper-server]] and
/// [[webui.llm-server]]. Apply / Save writes the currently selected profile into the matching default key
/// ([localapp] default-remote-asr-name, [webui] default-whisper-server-name, [webui] default-llm-server-name).
/// Local Service ([localapp.local-whisper]) holds the self-hosted whisper-server settings, separate from endpoint profiles.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let remoteTabID = "localapp.remote-asr"
    static let whisperTabID = "webui.whisper-server"
    static let llmTabID = "webui.llm-server"
    static let microphoneTabID = "localapp.microphone"
    static let localWhisperTabID = "localapp.local-whisper"
    static let recordingTabID = "localapp.recording"

    /// (new config, use Remote ASR as the active engine)
    var onSave: ((AirTypeConfig, Bool) -> Void)?
    /// Shared with the coordinator; owns the managed whisper-server process.
    var localWhisperServer: LocalWhisperServerManager?

    private let configPath: String
    private var window: NSWindow?
    private var baseConfig = AirTypeConfig()

    // Sidebar + detail (2-level: group headers + selectable leaves)
    private final class SidebarGroup: NSObject {
        let title: String
        var leaves: [SidebarLeaf]
        init(title: String, leaves: [SidebarLeaf]) {
            self.title = title
            self.leaves = leaves
        }
    }
    private final class SidebarLeaf: NSObject {
        let title: String
        /// config.json section ids shown in this pane (used to route `present(tab:)`).
        let sections: [String]
        /// Optional config path shown beside the detail title, e.g. `[localapp.local-whisper]`.
        let configPath: String?
        let view: NSView
        init(title: String, sections: [String], view: NSView, configPath: String? = nil) {
            self.title = title
            self.sections = sections
            self.configPath = configPath
            self.view = view
        }
    }
    private var groups: [SidebarGroup] = []
    private let sidebarOutline = NSOutlineView()
    private let detailContainer = NSView()
    private let detailTitle = NSTextField(labelWithString: "")
    private let detailConfigPath = NSTextField(labelWithString: "")
    private let detailTitleStack = NSStackView()
    private weak var selectedLeaf: SidebarLeaf?

    private struct FieldBinding {
        let descriptor: ConfigFieldDescriptor
        let get: () -> String
        let set: (String) -> Void
    }
    private var sectionBindings: [FieldBinding] = []

    // MARK: Endpoint profile sessions

    private lazy var asrSession = ProfileSession<RemoteASRConfig>(
        kind: "ASR", name: \.name,
        readEditor: { [unowned self] in self.readASREditor() },
        writeEditor: { [unowned self] in self.writeASREditor($0) }
    )
    private lazy var whisperSession = ProfileSession<WhisperServerConfig>(
        kind: "Whisper", name: \.name,
        readEditor: { [unowned self] in self.readWhisperEditor() },
        writeEditor: { [unowned self] in self.writeWhisperEditor($0) }
    )
    private lazy var llmSession = ProfileSession<LLMServerConfig>(
        kind: "LLM", name: \.name,
        readEditor: { [unowned self] in self.readLLMEditor() },
        writeEditor: { [unowned self] in self.writeLLMEditor($0) }
    )

    // Remote ASR form
    private let remoteNameField = NSTextField()
    private let remoteEndpointField = NSTextField()
    private let remoteProtocolPopup = NSPopUpButton()
    private let remoteAPIKeyField = NSSecureTextField()
    private let remoteModelCombo = NSComboBox()
    private let remoteFetchButton = NSButton()
    private let remoteFetchNote = NSTextField(wrappingLabelWithString: "")
    private var remoteEngineActive = false
    private let remoteTestButton = NSButton()
    private let remoteSpinner = NSProgressIndicator()
    private let remoteTestResult = NSTextField(wrappingLabelWithString: "")

    // Whisper endpoint form
    private var whisperBindings: [FieldBinding] = []
    private let whisperTestButton = NSButton()
    private let whisperSpinner = NSProgressIndicator()
    private let whisperTestResult = NSTextField(wrappingLabelWithString: "")

    // Local Service ▸ Whisper Server
    private let localServerBinField = NSTextField()
    private let localHostField = NSTextField()
    private let localPortField = NSTextField()
    private let localMaxThreadsField = NSTextField()
    private let localMaxGpuField = NSTextField()
    private let localBeamField = NSTextField()
    private let localTemperatureField = NSTextField()
    private let whisperModelDirField = NSTextField()
    private let whisperModelCombo = NSComboBox()
    private let whisperModelNote = NSTextField(wrappingLabelWithString: "")
    private let localEnabledCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let localToggleButton = NSButton()
    private let localServerStatus = NSTextField(wrappingLabelWithString: "Status: stopped")
    private let localTestButton = NSButton()
    private let localSpinner = NSProgressIndicator()
    private var localWhisperStartInFlight = false
    private var localWhisperLastError: String?

    // LLM form
    private var llmBindings: [FieldBinding] = []
    private let llmModelCombo = NSComboBox()
    private let llmFetchButton = NSButton()
    private let llmFetchNote = NSTextField(wrappingLabelWithString: "")
    private let llmTestButton = NSButton()
    private let llmSpinner = NSProgressIndicator()
    private let llmTestResult = NSTextField(wrappingLabelWithString: "")

    // Microphone
    private let micDevicePopup = NSPopUpButton()
    private let micDeviceNote = NSTextField(wrappingLabelWithString: "")
    private var micSelectedName = ""
    private var micDeviceSignature: [String] = []
    private var micObservers: [NSObjectProtocol] = []
    private var micTimer: Timer?

    // Behavior (Voice Input ▸ Behavior) — voice prefs; remote polish toggles are Settings-only
    private let recordingBackendPopup = NSPopUpButton()
    private let recordingLocalModelPopup = NSPopUpButton()
    private let recordingRemoteEndpointPopup = NSPopUpButton()
    private let recordingLanguagePopup = NSPopUpButton()
    private let recordingLiveTypingCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let recordingLLMPolishCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let recordingArabicNumeralsCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let recordingTaiwanPhrasesCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let recordingLiveTypingNote = NSTextField(wrappingLabelWithString: "")
    private let recordingRemoteEndpointNote = NSTextField(wrappingLabelWithString: "")
    private let recordingDetailLabel = NSTextField(labelWithString: "Local Model")
    private let recordingDetailHost = NSView()
    /// Local-only / Remote-only preference rows; toggled in `updateRecordingBackendUI`.
    private var recordingLiveTypingRow: NSView?
    private var recordingLLMPolishRow: NSView?
    private var recordingArabicNumeralsRow: NSView?
    private var recordingTaiwanPhrasesRow: NSView?
    private static let liveTypingDefaultsKey = "liveTypingEnabled"

    // Obsidian
    private let obsidianVaultField = NSTextField()

    // History panes (retain controllers while window lives)
    private var voiceHistoryPane: HistorySettingsPaneController?
    private var obsidianHistoryPane: HistorySettingsPaneController?

    private let footerStatus = NSTextField(labelWithString: "")

    init(configPath: String) {
        self.configPath = configPath
        super.init()
    }

    // MARK: - Presenting

    /// `tab` is a config.json section id (e.g. `localapp.remote-asr`, `webui.llm-server`, `webui.auth`).
    func present(config: AirTypeConfig, remoteActive: Bool, tab: String?) {
        if window == nil {
            buildWindow()
            installDeviceObservers()
        }
        guard let window else { return }
        if !window.isVisible {
            load(config: config, remoteActive: remoteActive)
            window.center()
        }
        if let tab {
            select(section: tab)
        } else if selectedLeaf == nil {
            selectFirstLeaf()
        }
        startMicTimer()
        // Stay .accessory (menu-bar app). Toggling .regular ↔ .accessory on open/close
        // makes macOS tear down and restore the status item — feels like an app restart.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func load(config: AirTypeConfig, remoteActive: Bool) {
        baseConfig = config
        for binding in sectionBindings {
            binding.set(ConfigStore.displayValue(section: binding.descriptor.section, key: binding.descriptor.key, in: config))
        }
        let fallback = config.backend.remoteEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        remoteEndpointField.placeholderString = fallback.isEmpty ? "" : fallback
        reloadSessions(from: config, keepSelection: false)
        refreshWhisperModels()
        refreshLocalWhisperServerControls()
        remoteEngineActive = remoteActive
        footerStatus.stringValue = ""
        refreshMicDevices(force: true)
        loadRecordingPrefs(config: config, remoteActive: remoteActive)
    }

    private func reloadSessions(from config: AirTypeConfig, keepSelection: Bool) {
        asrSession.load(
            config.remoteASRProfiles.isEmpty ? [config.remoteASR] : config.remoteASRProfiles,
            preferredName: config.selectedRemoteASRName.isEmpty ? config.remoteASR.name : config.selectedRemoteASRName,
            selecting: keepSelection ? asrSession.index : nil
        )
        whisperSession.load(
            config.webui.whisperServers.isEmpty ? [config.webui.whisper] : config.webui.whisperServers,
            preferredName: config.webui.selectedWhisperServerName.isEmpty ? config.webui.whisper.name : config.webui.selectedWhisperServerName,
            selecting: keepSelection ? whisperSession.index : nil
        )
        // Drop any legacy persisted `models` catalogs — config only keeps selected-model.
        let llmProfiles = (config.webui.llmServers.isEmpty ? [config.webui.llm] : config.webui.llmServers).map { profile -> LLMServerConfig in
            var profile = profile
            profile.models = []
            return profile
        }
        llmSession.load(
            llmProfiles,
            preferredName: config.webui.selectedServerName.isEmpty ? config.webui.llm.name : config.webui.selectedServerName,
            selecting: keepSelection ? llmSession.index : nil
        )
    }

    // MARK: - Window delegate

    func windowDidBecomeKey(_ notification: Notification) {
        refreshMicDevices(force: false)
    }

    func windowWillClose(_ notification: Notification) {
        micTimer?.invalidate()
        micTimer = nil
    }

    // MARK: - Window

    private func buildWindow() {
        let window = EditableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AirType Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 500)
        window.delegate = self

        buildCategories()

        // Sidebar (group headers + leaves, no icons)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.resizingMask = .autoresizingMask
        sidebarOutline.addTableColumn(column)
        sidebarOutline.outlineTableColumn = column
        sidebarOutline.headerView = nil
        sidebarOutline.style = .sourceList
        sidebarOutline.rowHeight = 28
        sidebarOutline.intercellSpacing = NSSize(width: 0, height: 2)
        sidebarOutline.allowsEmptySelection = false
        sidebarOutline.focusRingType = .none
        sidebarOutline.indentationPerLevel = 12
        sidebarOutline.floatsGroupRows = false
        sidebarOutline.dataSource = self
        sidebarOutline.delegate = self
        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebarOutline
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        sidebarScroll.borderType = .noBorder
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .followsWindowActiveState
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarScroll)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        // Detail
        detailTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        detailTitle.setContentHuggingPriority(.required, for: .horizontal)
        detailConfigPath.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        detailConfigPath.textColor = .secondaryLabelColor
        detailConfigPath.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailTitleStack.orientation = .horizontal
        detailTitleStack.alignment = .lastBaseline
        detailTitleStack.spacing = 10
        detailTitleStack.addArrangedSubview(detailTitle)
        detailTitleStack.addArrangedSubview(detailConfigPath)
        detailTitleStack.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.translatesAutoresizingMaskIntoConstraints = false

        // Footer
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
        content.addSubview(sidebar)
        content.addSubview(separator)
        content.addSubview(detailTitleStack)
        content.addSubview(detailContainer)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 200),
            sidebarScroll.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 10),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -10),
            separator.topAnchor.constraint(equalTo: content.topAnchor),
            separator.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            detailTitleStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            detailTitleStack.leadingAnchor.constraint(equalTo: separator.trailingAnchor, constant: 12),
            detailTitleStack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            detailContainer.topAnchor.constraint(equalTo: detailTitleStack.bottomAnchor, constant: 12),
            detailContainer.leadingAnchor.constraint(equalTo: separator.trailingAnchor, constant: 6),
            detailContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            footer.topAnchor.constraint(equalTo: detailContainer.bottomAnchor, constant: 10),
            footer.leadingAnchor.constraint(equalTo: separator.trailingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        window.contentView = content
        self.window = window
        sidebarOutline.reloadData()
        for group in groups {
            sidebarOutline.expandItem(group, expandChildren: false)
        }
    }

    /// Sidebar groups and leaves, in display order. Each leaf is built from its config.json section(s).
    private func buildCategories() {
        let descriptors = Dictionary(ConfigStore.sectionDescriptors.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        func leaf(
            _ title: String,
            _ id: String,
            extraSections: [String] = [],
            configPath: String? = nil,
            builder: (ConfigSectionDescriptor) -> NSView
        ) -> SidebarLeaf? {
            guard let section = descriptors[id] else { return nil }
            return SidebarLeaf(
                title: title,
                sections: [id] + extraSections,
                view: builder(section),
                configPath: configPath
            )
        }

        let providerLeaves: [SidebarLeaf] = [
            leaf(
                "Whisper Server",
                Self.localWhisperTabID,
                configPath: "[localapp.local-whisper]",
                builder: buildLocalWhisperTab
            )
        ].compactMap { $0 }

        let endpointLeaves: [SidebarLeaf] = [
            leaf("ASR Endpoints", Self.remoteTabID, extraSections: ["localapp"], builder: buildRemoteTab),
            leaf(
                "LLM Endpoints",
                Self.llmTabID,
                extraSections: ["webui"],
                configPath: "[webui.llm-server]",
                builder: buildLLMTab
            ),
            leaf("Whisper Endpoints", Self.whisperTabID, builder: buildWhisperTab)
        ].compactMap { $0 }

        var voiceLeaves: [SidebarLeaf] = [
            leaf(
                "Behavior",
                Self.recordingTabID,
                configPath: "[localapp.recording]",
                builder: buildRecordingTab
            )
        ].compactMap { $0 }
        voiceLeaves.append(SidebarLeaf(title: "History", sections: ["voice.history"], view: buildVoiceHistoryTab()))

        let otherLeaves: [SidebarLeaf] = [
            leaf("Microphone", Self.microphoneTabID, builder: buildMicrophoneTab)
        ].compactMap { $0 }

        var obsidianLeaves: [SidebarLeaf] = [
            leaf("Config", "localapp.obsidian", builder: buildObsidianTab)
        ].compactMap { $0 }
        obsidianLeaves.append(SidebarLeaf(title: "History", sections: ["obsidian.history"], view: buildObsidianHistoryTab()))

        groups = [
            SidebarGroup(title: "Service Providers", leaves: providerLeaves),
            SidebarGroup(title: "Endpoint Profiles", leaves: endpointLeaves),
            SidebarGroup(title: "Voice Input", leaves: voiceLeaves),
            SidebarGroup(title: "Others", leaves: otherLeaves),
            SidebarGroup(title: "Obsidian", leaves: obsidianLeaves)
        ].filter { !$0.leaves.isEmpty }
    }

    private func select(section: String) {
        for group in groups {
            if let leaf = group.leaves.first(where: { $0.sections.contains(section) }) {
                selectLeaf(leaf)
                return
            }
        }
        if selectedLeaf == nil { selectFirstLeaf() }
    }

    private func selectFirstLeaf() {
        guard let leaf = groups.first?.leaves.first else { return }
        selectLeaf(leaf)
    }

    private func selectLeaf(_ leaf: SidebarLeaf) {
        let row = sidebarOutline.row(forItem: leaf)
        if row >= 0, sidebarOutline.selectedRow != row {
            sidebarOutline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        showLeaf(leaf)
    }

    private func showLeaf(_ leaf: SidebarLeaf) {
        if selectedLeaf === leaf { return }
        selectedLeaf = leaf
        detailTitle.stringValue = leaf.title
        if let path = leaf.configPath, !path.isEmpty {
            detailConfigPath.stringValue = path
            detailConfigPath.isHidden = false
        } else {
            detailConfigPath.stringValue = ""
            detailConfigPath.isHidden = true
        }
        detailContainer.subviews.forEach { $0.removeFromSuperview() }
        let view = leaf.view
        view.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor)
        ])
        if leaf.sections.contains(Self.microphoneTabID) {
            refreshMicDevices(force: false)
        }
        if leaf.sections.contains(Self.localWhisperTabID) {
            refreshLocalWhisperServerControls()
        }
    }

    // MARK: - Sidebar outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return groups.count }
        if let group = item as? SidebarGroup { return group.leaves.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return groups[index] }
        return (item as! SidebarGroup).leaves[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SidebarGroup
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is SidebarGroup
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SidebarLeaf
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        // Always-visible groups; hide the disclosure triangle for a System Settings-like look.
        false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? SidebarGroup {
            let id = NSUserInterfaceItemIdentifier("SidebarGroupCell")
            let cell: NSTableCellView
            if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = id
                let text = NSTextField(labelWithString: "")
                text.translatesAutoresizingMaskIntoConstraints = false
                text.font = .systemFont(ofSize: 11, weight: .semibold)
                text.textColor = .secondaryLabelColor
                text.lineBreakMode = .byTruncatingTail
                cell.addSubview(text)
                cell.textField = text
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            cell.textField?.stringValue = group.title.uppercased()
            return cell
        }
        if let leaf = item as? SidebarLeaf {
            let id = NSUserInterfaceItemIdentifier("SidebarLeafCell")
            let cell: NSTableCellView
            if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = id
                let text = NSTextField(labelWithString: "")
                text.translatesAutoresizingMaskIntoConstraints = false
                text.lineBreakMode = .byTruncatingTail
                cell.addSubview(text)
                cell.textField = text
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                    text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            cell.textField?.stringValue = leaf.title
            return cell
        }
        return nil
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = sidebarOutline.selectedRow
        guard row >= 0, let leaf = sidebarOutline.item(atRow: row) as? SidebarLeaf else { return }
        showLeaf(leaf)
    }

    private static func fieldLabel(_ key: String) -> String {
        switch key {
        case "vault_path": return "Vault Path"
        case "default_folder": return "Default Folder"
        case "api_key": return "API Key"
        case "contextLength": return "Context Length"
        case "selected-model": return "Model Name"
        case "default-llm-server-name": return "Default Server"
        case "model_dir": return "Model Path"
        case "server_bin": return "File Path"
        case "server_args": return "Advanced Args"
        case "model_filename": return "Model File"
        case "hotkey_press_count": return "Hotkey Presses"
        case "hotkey_trigger": return "Hotkey"
        case "play_cues": return "Play Cues"
        case "max_threads": return "Max Thread Number"
        case "max_gpu": return "Max GPU Number"
        case "host": return "Host IP"
        case "port": return "Host Port"
        case "vocabulary_prompt": return "Vocabulary Prompt"
        case "no_timestamps": return "No Timestamp"
        case "no_language_symbol": return "No Language Symbol"
        case "thinking": return "Thinking"
        case "remote_endpoint": return "Endpoint URL"
        case "system": return "System Prompt"
        default:
            return key.split(whereSeparator: { $0 == "_" || $0 == "-" })
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    // MARK: - Generic section panes

    private func buildSectionTab(_ section: ConfigSectionDescriptor) -> NSView {
        buildCustomSectionTab(section, overrides: [:])
    }

    /// Generic `[section]` form; `overrides` supplies custom controls for specific keys.
    /// `rowsAfterKey` inserts extra rows immediately after the named field (e.g. after `enabled`).
    /// `skipKeys` omits a field's own row (bindings must be registered by an override that consumes them).
    private func buildCustomSectionTab(_ section: ConfigSectionDescriptor,
                                       overrides: [String: (ConfigFieldDescriptor) -> (NSView, FieldBinding)],
                                       extraRows: [NSView] = [],
                                       rowsAfterKey: [String: [NSView]] = [:],
                                       skipKeys: Set<String> = [],
                                       showSectionHeader: Bool = true) -> NSView {
        var rows: [NSView] = []
        if showSectionHeader {
            rows.append(sectionHeader("[\(section.name)]"))
        }
        for field in section.fields {
            if skipKeys.contains(field.key) { continue }
            let (control, binding) = overrides[field.key]?(field) ?? makeControl(field)
            sectionBindings.append(binding)
            rows.append(row(label: Self.fieldLabel(field.key), key: field.key, control: control, comment: field.comment))
            if let inserted = rowsAfterKey[field.key] {
                rows.append(contentsOf: inserted)
            }
        }
        return scrollWrap(rows + extraRows)
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
            popup.font = Self.fieldFont
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
        styleEditableField(text)
        _ = 0
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
        name.font = Self.fieldFont
        name.toolTip = key
        name.widthAnchor.constraint(equalToConstant: 128).isActive = true
        let right = NSStackView(views: [control])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 3
        _ = comment
        let stack = NSStackView(views: [name, right])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        return stack
    }

    private func scrollWrap(_ rows: [NSView]) -> NSView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
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
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        return scroll
    }

    // MARK: - Small helpers

    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func expandPath(_ path: String) -> String {
        (trim(path) as NSString).expandingTildeInPath
    }

    private func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func vstack(_ views: [NSView], spacing: CGFloat = 4) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }


    /// Readable outline for editable fields. Default macOS bezels wash out on the large Settings pane.
    private static let fieldOutlineColor = NSColor(calibratedWhite: 0.52, alpha: 1)

    static let fieldFont = NSFont.systemFont(ofSize: 13)

    private func styleEditableField(_ field: NSTextField) {
        let multiline = !(field.cell?.usesSingleLineMode ?? true) && (field.cell?.wraps ?? false)
        let padded: NSTextFieldCell = field is NSSecureTextField ? PaddedSecureTextFieldCell(textCell: "") : PaddedTextFieldCell(textCell: "")
        padded.isEditable = true
        padded.isSelectable = true
        padded.isScrollable = !multiline
        padded.wraps = multiline
        padded.usesSingleLineMode = !multiline
        padded.placeholderString = field.placeholderString
        field.cell = padded
        field.font = Self.fieldFont
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.focusRingType = .exterior
        field.wantsLayer = true
        field.layer?.masksToBounds = true
        field.layer?.cornerRadius = 5
        field.layer?.borderWidth = 1
        field.layer?.borderColor = Self.fieldOutlineColor.cgColor
        let h = field.heightAnchor.constraint(greaterThanOrEqualToConstant: 26)
        h.isActive = true
    }

    private func styleEditableCombo(_ combo: NSComboBox) {
        combo.font = Self.fieldFont
        combo.isBordered = true
        combo.isBezeled = true
        combo.drawsBackground = true
        combo.focusRingType = .exterior
        combo.wantsLayer = true
        combo.layer?.masksToBounds = true
        combo.layer?.cornerRadius = 5
        combo.layer?.borderWidth = 1
        combo.layer?.borderColor = Self.fieldOutlineColor.cgColor
    }

    private func noteStyle(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 480
        label.isSelectable = true
    }

    private func setupTestControls(button: NSButton, spinner: NSProgressIndicator, result: NSTextField, action: Selector) -> NSView {
        button.title = "Test"
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        result.isSelectable = true
        result.preferredMaxLayoutWidth = 480
        return vstack([hstack([button, spinner]), result], spacing: 6)
    }

    private static func show(_ text: String, ok: Bool?, in label: NSTextField) {
        label.stringValue = text
        switch ok {
        case .some(true): label.textColor = .systemGreen
        case .some(false): label.textColor = .systemRed
        case .none: label.textColor = .secondaryLabelColor
        }
    }

    /// Replaces the path field with the Browse result (full overwrite, never append).
    /// Syncs any active field editor first, then resigns focus so sheet dismissal
    /// cannot restore the pre-browse text.
    private func applyBrowsedPath(_ path: String, to field: NSTextField) {
        if let editor = field.currentEditor() {
            editor.string = path
            editor.selectedRange = NSRange(location: (path as NSString).length, length: 0)
        }
        field.stringValue = path
        window?.makeFirstResponder(nil)
    }

    private func chooseDirectory(startingAt path: String, message: String, completion: @escaping (String) -> Void) {
        window?.endEditing(for: nil)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = "Choose"
        let expanded = Self.expandPath(path)
        if !expanded.isEmpty, FileManager.default.fileExists(atPath: expanded) {
            panel.directoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
        }
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { completion(url.path) }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    // MARK: - Remote ASR pane ([[localapp.remote-asr]])

    private func buildRemoteTab(_ section: ConfigSectionDescriptor) -> NSView {
        styleEditableField(remoteNameField)
        remoteNameField.placeholderString = ""
        remoteNameField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        styleEditableField(remoteEndpointField)
        remoteEndpointField.placeholderString = ""
        remoteEndpointField.widthAnchor.constraint(equalToConstant: 480).isActive = true
        for kind in RemoteASRProtocol.allCases {
            remoteProtocolPopup.addItem(withTitle: kind.title)
            remoteProtocolPopup.lastItem?.representedObject = kind.rawValue
        }
        styleEditableField(remoteAPIKeyField)
        remoteAPIKeyField.placeholderString = ""
        remoteAPIKeyField.widthAnchor.constraint(equalToConstant: 480).isActive = true
        styleEditableCombo(remoteModelCombo)
        remoteModelCombo.completes = true
        remoteModelCombo.numberOfVisibleItems = 14
        remoteModelCombo.widthAnchor.constraint(equalToConstant: 360).isActive = true
        remoteFetchButton.title = "Fetch Models"
        remoteFetchButton.bezelStyle = .rounded
        remoteFetchButton.target = self
        remoteFetchButton.action = #selector(fetchRemoteModels)
        noteStyle(remoteFetchNote)
        let modelStack = vstack([hstack([remoteModelCombo, remoteFetchButton]), remoteFetchNote])
        let testStack = setupTestControls(button: remoteTestButton, spinner: remoteSpinner, result: remoteTestResult, action: #selector(testRemote))

                let rows: [NSView] = [
            sectionHeader("[[\(section.name)]]"),
            row(label: "Profiles", key: nil, control: asrSession.panel.view, comment: nil),
            row(label: "Name", key: "name", control: remoteNameField, comment: nil),
            row(label: "Endpoint", key: "endpoint", control: remoteEndpointField, comment: nil),
            row(label: "Protocol", key: "protocol", control: remoteProtocolPopup, comment: nil),
            row(label: "API Key", key: "api_key", control: remoteAPIKeyField, comment: nil),
            row(label: "Model", key: "model", control: modelStack, comment: nil),
            row(label: "Test", key: nil, control: testStack, comment: nil)
        ]
        return scrollWrap(rows)
    }

    private func readASREditor() -> RemoteASRConfig {
        RemoteASRConfig(
            name: Self.trim(remoteNameField.stringValue),
            endpoint: Self.trim(remoteEndpointField.stringValue),
            protocolName: selectedProtocol.rawValue,
            model: Self.trim(remoteModelCombo.stringValue),
            apiKey: Self.trim(remoteAPIKeyField.stringValue)
        )
    }

    private func writeASREditor(_ profile: RemoteASRConfig) {
        remoteNameField.stringValue = profile.name
        remoteEndpointField.stringValue = profile.endpoint
        selectProtocol(RemoteASRProtocol(rawValue: profile.protocolName) ?? .webuiIME)
        remoteAPIKeyField.stringValue = profile.apiKey
        remoteModelCombo.removeAllItems()
        remoteModelCombo.stringValue = profile.model
        remoteFetchNote.stringValue = ""
        remoteTestResult.stringValue = ""
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
        let config = collectConfig()
        guard let endpoint = RemoteWhisperSettings.normalize(remoteEndpointField.stringValue)
            ?? RemoteWhisperSettings.normalize(config.backend.remoteEndpoint) else { return nil }
        return RemoteASRTarget(
            endpoint: endpoint,
            protocolKind: selectedProtocol,
            model: Self.trim(remoteModelCombo.stringValue),
            apiKey: Self.trim(remoteAPIKeyField.stringValue),
            auth: config.webui.auth
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
        Self.show(text, ok: ok, in: remoteTestResult)
    }

    // MARK: - Whisper endpoint pane ([[webui.whisper-server]])

    private func buildWhisperTab(_ section: ConfigSectionDescriptor) -> NSView {
        var rows: [NSView] = [
            sectionHeader("[[\(section.name)]]"),
            row(label: "Profiles", key: nil, control: whisperSession.panel.view, comment: nil)
        ]
        for field in section.fields {
            let (control, binding) = makeControl(field)
            if field.key == "name", let text = control as? NSTextField {
                text.removeConstraints(text.constraints.filter { $0.firstAttribute == .width })
                text.widthAnchor.constraint(equalToConstant: 240).isActive = true
            }
            whisperBindings.append(binding)
            let label = field.key == "remote_endpoint" ? "Endpoint" : Self.fieldLabel(field.key)
            rows.append(row(label: label, key: field.key, control: control, comment: nil))
        }
        let testStack = setupTestControls(button: whisperTestButton, spinner: whisperSpinner, result: whisperTestResult, action: #selector(testWhisper))
        rows.append(row(label: "Test", key: nil, control: testStack, comment: nil))
        return scrollWrap(rows)
    }

    private func readWhisperEditor() -> WhisperServerConfig {
        var scratch = baseConfig
        scratch.webui.whisper = WhisperServerConfig()
        for binding in whisperBindings {
            ConfigStore.apply(section: binding.descriptor.section, key: binding.descriptor.key, value: binding.get(), to: &scratch)
        }
        return scratch.webui.whisper
    }

    private func writeWhisperEditor(_ profile: WhisperServerConfig) {
        var scratch = baseConfig
        scratch.webui.whisper = profile
        for binding in whisperBindings {
            binding.set(ConfigStore.displayValue(section: binding.descriptor.section, key: binding.descriptor.key, in: scratch))
        }
        whisperTestResult.stringValue = ""
    }

    @objc private func testWhisper() {
        let profile = readWhisperEditor()
        guard let endpoint = RemoteWhisperSettings.normalize(profile.remoteEndpoint) else {
            Self.show("Enter an endpoint first.", ok: false, in: whisperTestResult)
            return
        }
        whisperTestButton.isEnabled = false
        whisperSpinner.startAnimation(nil)
        Self.show("Checking \(endpoint)…", ok: nil, in: whisperTestResult)
        Task { @MainActor in
            var line = ""
            var ok = false
            for path in ["/health", "/"] {
                guard let url = URL(string: endpoint + path) else { continue }
                do {
                    let (_, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8))
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if (200..<300).contains(status) {
                        ok = true
                        line = "✓ \(endpoint)\(path) answered HTTP \(status)"
                        break
                    }
                    line = "✗ \(endpoint)\(path) answered HTTP \(status)"
                } catch {
                    line = "✗ \(endpoint) unreachable – \(error.localizedDescription)"
                    break
                }
            }
            Logger.shared.log("Settings: whisper test profile=\(profile.name), endpoint=\(endpoint), ok=\(ok), result=\(line)")
            whisperSpinner.stopAnimation(nil)
            whisperTestButton.isEnabled = true
            Self.show(line, ok: ok, in: whisperTestResult)
        }
    }

    // MARK: - Local Service ▸ Whisper Server pane ([localapp.local-whisper])

    private func buildLocalWhisperTab(_ section: ConfigSectionDescriptor) -> NSView {
        // Match generic text fields (Advanced Args / Vocabulary Prompt use 480 in makeControl).
        let fieldWidth: CGFloat = 480
        // Shared width for Start / Check / Browse… / Refresh so every action button matches.
        let actionButtonWidth: CGFloat = 88
        // Enabled is launch preference only (next app start); no immediate process side effects.
        localEnabledCheckbox.target = nil
        localEnabledCheckbox.action = nil
        localToggleButton.title = "Start"
        localToggleButton.bezelStyle = .rounded
        localToggleButton.controlSize = .large
        localToggleButton.target = self
        localToggleButton.action = #selector(toggleLocalWhisperServer)
        localTestButton.title = "Check"
        localTestButton.bezelStyle = .rounded
        localTestButton.controlSize = .large
        localTestButton.target = self
        localTestButton.action = #selector(checkLocalWhisperStatus)
        // Keep Start/Check the same size even when the title flips to Stop.
        localToggleButton.widthAnchor.constraint(equalToConstant: actionButtonWidth).isActive = true
        localTestButton.widthAnchor.constraint(equalToConstant: actionButtonWidth).isActive = true
        localToggleButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        localTestButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        localSpinner.style = .spinning
        localSpinner.controlSize = .small
        localSpinner.isDisplayedWhenStopped = false
        localServerStatus.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        localServerStatus.textColor = .secondaryLabelColor
        localServerStatus.isSelectable = true
        localServerStatus.alignment = .left
        localServerStatus.maximumNumberOfLines = 2
        localServerStatus.usesSingleLineMode = false
        localServerStatus.lineBreakMode = .byWordWrapping
        localServerStatus.cell?.wraps = true
        localServerStatus.preferredMaxLayoutWidth = fieldWidth
        localServerStatus.setContentHuggingPriority(.defaultLow, for: .horizontal)
        localServerStatus.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        return buildCustomSectionTab(section, overrides: [
            "enabled": { [unowned self] field in
                let box = self.localEnabledCheckbox
                // Row 1: controls; Row 2: Status (up to 2 lines, left-aligned).
                let buttons = self.hstack([
                    box,
                    self.localToggleButton,
                    self.localTestButton,
                    self.localSpinner
                ], spacing: 8)
                let stack = self.vstack([buttons, self.localServerStatus], spacing: 6)
                stack.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
                let binding = FieldBinding(
                    descriptor: field,
                    get: { box.state == .on ? "true" : "false" },
                    set: { box.state = ["true", "1", "yes", "on"].contains($0.lowercased()) ? .on : .off }
                )
                return (stack, binding)
            },
            "server_bin": { [unowned self] field in
                let text = self.localServerBinField
                self.styleEditableField(text)
                text.widthAnchor.constraint(equalToConstant: fieldWidth - actionButtonWidth - 8).isActive = true
                text.placeholderString = "whisper-server"
                let browse = NSButton(title: "Browse…", target: self, action: #selector(self.browseLocalServerBin))
                browse.bezelStyle = .rounded
                browse.controlSize = .regular
                browse.widthAnchor.constraint(equalToConstant: actionButtonWidth).isActive = true
                let binding = FieldBinding(descriptor: field, get: { text.stringValue }, set: { text.stringValue = $0 })
                let combined = self.hstack([text, browse], spacing: 8)
                combined.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
                return (combined, binding)
            },
            "host": { [unowned self] field in
                let host = self.localHostField
                let port = self.localPortField
                self.styleEditableField(host)
                self.styleEditableField(port)
                host.placeholderString = "127.0.0.1"
                port.placeholderString = "8080"
                port.widthAnchor.constraint(equalToConstant: 72).isActive = true
                host.setContentHuggingPriority(.defaultLow, for: .horizontal)
                host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                if let portField = section.fields.first(where: { $0.key == "port" }) {
                    self.sectionBindings.append(FieldBinding(
                        descriptor: portField,
                        get: { port.stringValue },
                        set: { port.stringValue = $0 }
                    ))
                }
                let portLabel = NSTextField(labelWithString: "Port")
                portLabel.font = Self.fieldFont
                portLabel.textColor = .secondaryLabelColor
                let combined = self.hstack([host, portLabel, port], spacing: 8)
                combined.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
                let binding = FieldBinding(descriptor: field, get: { host.stringValue }, set: { host.stringValue = $0 })
                return (combined, binding)
            },
            "max_threads": { [unowned self] field in
                let threads = self.localMaxThreadsField
                let gpu = self.localMaxGpuField
                self.styleEditableField(threads)
                self.styleEditableField(gpu)
                threads.placeholderString = "4"
                gpu.placeholderString = "1"
                gpu.widthAnchor.constraint(equalToConstant: 72).isActive = true
                threads.setContentHuggingPriority(.defaultLow, for: .horizontal)
                threads.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                if let gpuField = section.fields.first(where: { $0.key == "max_gpu" }) {
                    self.sectionBindings.append(FieldBinding(
                        descriptor: gpuField,
                        get: { gpu.stringValue },
                        set: { gpu.stringValue = $0 }
                    ))
                }
                let gpuLabel = NSTextField(labelWithString: "Max GPU")
                gpuLabel.font = Self.fieldFont
                gpuLabel.textColor = .secondaryLabelColor
                let combined = self.hstack([threads, gpuLabel, gpu], spacing: 8)
                combined.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
                let binding = FieldBinding(descriptor: field, get: { threads.stringValue }, set: { threads.stringValue = $0 })
                return (combined, binding)
            },
            "model_dir": { [unowned self] field in
                let text = self.whisperModelDirField
                self.styleEditableField(text)
                text.widthAnchor.constraint(equalToConstant: fieldWidth - actionButtonWidth - 8).isActive = true
                text.target = self
                text.action = #selector(self.refreshWhisperModels)
                let browse = NSButton(title: "Browse…", target: self, action: #selector(self.browseWhisperModelDir))
                browse.bezelStyle = .rounded
                browse.controlSize = .regular
                browse.widthAnchor.constraint(equalToConstant: actionButtonWidth).isActive = true
                let binding = FieldBinding(descriptor: field, get: { text.stringValue }, set: { text.stringValue = $0 })
                let combined = self.hstack([text, browse], spacing: 8)
                combined.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
                return (combined, binding)
            },
            "model_filename": { [unowned self] field in
                let combo = self.whisperModelCombo
                self.styleEditableCombo(combo)
                combo.completes = true
                combo.numberOfVisibleItems = 14
                combo.widthAnchor.constraint(equalToConstant: fieldWidth - actionButtonWidth - 8).isActive = true
                let refresh = NSButton(title: "Refresh", target: self, action: #selector(self.refreshWhisperModels))
                refresh.bezelStyle = .rounded
                refresh.controlSize = .regular
                refresh.widthAnchor.constraint(equalToConstant: actionButtonWidth).isActive = true
                self.noteStyle(self.whisperModelNote)
                let binding = FieldBinding(descriptor: field, get: { combo.stringValue }, set: { combo.stringValue = $0 })
                let combined = self.hstack([combo, refresh], spacing: 8)
                combined.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
                return (self.vstack([combined, self.whisperModelNote]), binding)
            },
            "language": { [unowned self] field in
                let popup = NSPopUpButton()
                popup.font = Self.fieldFont
                popup.removeAllItems()
                popup.addItems(withTitles: field.options.isEmpty ? ["zh-tw", "zh-cn", "en", "auto"] : field.options)
                popup.widthAnchor.constraint(equalToConstant: 110).isActive = true
                let beam = self.localBeamField
                let temperature = self.localTemperatureField
                self.styleEditableField(beam)
                self.styleEditableField(temperature)
                beam.placeholderString = "5"
                temperature.placeholderString = "0"
                beam.widthAnchor.constraint(equalToConstant: 56).isActive = true
                temperature.widthAnchor.constraint(equalToConstant: 56).isActive = true
                if let beamField = section.fields.first(where: { $0.key == "beam" }) {
                    self.sectionBindings.append(FieldBinding(
                        descriptor: beamField,
                        get: { beam.stringValue },
                        set: { beam.stringValue = $0 }
                    ))
                }
                if let temperatureField = section.fields.first(where: { $0.key == "temperature" }) {
                    self.sectionBindings.append(FieldBinding(
                        descriptor: temperatureField,
                        get: { temperature.stringValue },
                        set: { temperature.stringValue = $0 }
                    ))
                }
                let beamLabel = NSTextField(labelWithString: "Beam")
                beamLabel.font = Self.fieldFont
                beamLabel.textColor = .secondaryLabelColor
                let temperatureLabel = NSTextField(labelWithString: "Temperature")
                temperatureLabel.font = Self.fieldFont
                temperatureLabel.textColor = .secondaryLabelColor
                let spacer = NSView()
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let combined = self.hstack([
                    popup,
                    spacer,
                    beamLabel,
                    beam,
                    temperatureLabel,
                    temperature
                ], spacing: 8)
                combined.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
                let binding = FieldBinding(
                    descriptor: field,
                    get: { popup.titleOfSelectedItem ?? "zh-tw" },
                    set: { value in
                        if popup.item(withTitle: value) == nil, !value.isEmpty {
                            popup.addItem(withTitle: value)
                        }
                        popup.selectItem(withTitle: value.isEmpty ? "zh-tw" : value)
                    }
                )
                return (combined, binding)
            },
            "no_timestamps": { [unowned self] field in
                let noTimestamps = NSButton(checkboxWithTitle: "", target: nil, action: nil)
                let noLanguageSymbol = NSButton(checkboxWithTitle: "", target: nil, action: nil)
                if let languageSymbolField = section.fields.first(where: { $0.key == "no_language_symbol" }) {
                    self.sectionBindings.append(FieldBinding(
                        descriptor: languageSymbolField,
                        get: { noLanguageSymbol.state == .on ? "true" : "false" },
                        set: {
                            noLanguageSymbol.state = ["true", "1", "yes", "on"].contains($0.lowercased()) ? .on : .off
                        }
                    ))
                }
                let languageSymbolLabel = NSTextField(labelWithString: "No Language Symbol")
                languageSymbolLabel.font = Self.fieldFont
                languageSymbolLabel.textColor = .secondaryLabelColor
                let spacer = NSView()
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let combined = self.hstack([
                    noTimestamps,
                    spacer,
                    languageSymbolLabel,
                    noLanguageSymbol
                ], spacing: 8)
                combined.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
                let binding = FieldBinding(
                    descriptor: field,
                    get: { noTimestamps.state == .on ? "true" : "false" },
                    set: {
                        noTimestamps.state = ["true", "1", "yes", "on"].contains($0.lowercased()) ? .on : .off
                    }
                )
                return (combined, binding)
            }
        ], skipKeys: ["port", "max_gpu", "beam", "temperature", "no_language_symbol"], showSectionHeader: false)
    }

    private func setLocalWhisperStatus(_ detail: String, ok: Bool?) {
        localServerStatus.stringValue = "Status: \(detail)"
        switch ok {
        case .some(true): localServerStatus.textColor = .systemGreen
        case .some(false): localServerStatus.textColor = .systemRed
        case .none: localServerStatus.textColor = .secondaryLabelColor
        }
    }

    /// Refresh Start/Stop label and Status from the live managed process (Enabled is unrelated).
    func refreshLocalWhisperServerControls(syncFinished: Bool = false) {
        _ = syncFinished
        let running = localWhisperServer?.isRunning == true
        if localWhisperStartInFlight {
            localToggleButton.title = "Stop"
            localToggleButton.isEnabled = false
            setLocalWhisperStatus("starting…", ok: nil)
            return
        }
        localSpinner.stopAnimation(nil)
        localToggleButton.title = running ? "Stop" : "Start"
        localToggleButton.isEnabled = localWhisperServer != nil

        if running {
            localWhisperLastError = nil
            setLocalWhisperStatus(localWhisperServer?.statusText ?? "running", ok: true)
        } else if let error = localWhisperLastError, !error.isEmpty {
            setLocalWhisperStatus(error, ok: false)
        } else {
            setLocalWhisperStatus("stopped", ok: nil)
        }
    }

    func showLocalWhisperServerMessage(_ text: String, ok: Bool?) {
        if ok == false {
            localWhisperLastError = text
            setLocalWhisperStatus(text, ok: false)
        } else if ok == true {
            localWhisperLastError = nil
            setLocalWhisperStatus(text, ok: true)
        } else {
            setLocalWhisperStatus(text, ok: nil)
        }
    }

    @objc private func checkLocalWhisperStatus() {
        localWhisperLastError = nil
        refreshLocalWhisperServerControls()
    }

    @objc private func toggleLocalWhisperServer() {
        if localWhisperServer?.isRunning == true {
            stopLocalWhisperServerNow()
        } else {
            startLocalWhisperServerNow()
        }
    }

    private func startLocalWhisperServerNow() {
        guard let localWhisperServer else {
            showLocalWhisperServerMessage("Whisper server manager is unavailable.", ok: false)
            return
        }
        let config = collectConfig().localWhisper
        localWhisperLastError = nil
        localWhisperStartInFlight = true
        localToggleButton.title = "Stop"
        localToggleButton.isEnabled = false
        localSpinner.startAnimation(nil)
        setLocalWhisperStatus("starting…", ok: nil)
        Task { @MainActor in
            defer {
                self.localWhisperStartInFlight = false
                self.localSpinner.stopAnimation(nil)
                self.refreshLocalWhisperServerControls()
            }
            do {
                try await localWhisperServer.start(config)
                self.localWhisperLastError = nil
            } catch {
                self.localWhisperLastError = error.localizedDescription
            }
        }
    }

    private func stopLocalWhisperServerNow() {
        localWhisperServer?.stop()
        localWhisperLastError = nil
        localWhisperStartInFlight = false
        localSpinner.stopAnimation(nil)
        refreshLocalWhisperServerControls()
    }

    @objc private func browseLocalServerBin() {
        window?.endEditing(for: nil)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Choose"
        let current = Self.expandPath(localServerBinField.stringValue)
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (current as NSString).deletingLastPathComponent, isDirectory: true)
        }
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.applyBrowsedPath(url.path, to: self.localServerBinField)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    @objc private func browseWhisperModelDir() {
        chooseDirectory(startingAt: whisperModelDirField.stringValue, message: "Choose the folder that holds whisper.cpp ggml models") { [weak self] path in
            guard let self else { return }
            self.applyBrowsedPath((path as NSString).abbreviatingWithTildeInPath, to: self.whisperModelDirField)
            self.refreshWhisperModels()
        }
    }

    /// Lists ggml model files (*.bin / *.gguf) in model_dir into the model_filename combo.
    @objc private func refreshWhisperModels() {
        let dir = Self.expandPath(whisperModelDirField.stringValue)
        whisperModelCombo.removeAllItems()
        guard !dir.isEmpty else {
            whisperModelNote.stringValue = ""
            return
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            whisperModelNote.stringValue = "Folder not found: \(dir)"
            return
        }
        let models = names.filter { $0.hasSuffix(".bin") || $0.hasSuffix(".gguf") }.sorted()
        whisperModelCombo.addItems(withObjectValues: models)
        let current = Self.trim(whisperModelCombo.stringValue)
        if current.isEmpty, let first = models.first { whisperModelCombo.stringValue = first }
        whisperModelNote.stringValue = !current.isEmpty && !models.contains(current) ? "“\(current)” is not in this folder" : ""
    }

    // MARK: - LLM pane ([[webui.llm-server]])

    private func buildLLMTab(_ section: ConfigSectionDescriptor) -> NSView {
        // Match Whisper Server Preferences density: shared 480 control column, 88 action buttons.
        let fieldWidth: CGFloat = 480
        let actionButtonWidth: CGFloat = 88
        llmBindings.removeAll()

        var rows: [NSView] = [
            row(label: "Profiles", key: nil, control: llmSession.panel.view, comment: nil)
        ]

        func appendBinding(_ binding: FieldBinding) {
            llmBindings.append(binding)
        }

        // Name + Provider
        if let nameField = section.fields.first(where: { $0.key == "name" }) {
            let name = NSTextField()
            let provider = NSTextField()
            styleEditableField(name)
            styleEditableField(provider)
            name.setContentHuggingPriority(.defaultLow, for: .horizontal)
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            provider.widthAnchor.constraint(equalToConstant: 140).isActive = true
            if let providerField = section.fields.first(where: { $0.key == "provider" }) {
                appendBinding(FieldBinding(descriptor: providerField, get: { provider.stringValue }, set: { provider.stringValue = $0 }))
            }
            let providerLabel = NSTextField(labelWithString: "Provider")
            providerLabel.font = Self.fieldFont
            providerLabel.textColor = .secondaryLabelColor
            let combined = hstack([name, providerLabel, provider], spacing: 8)
            combined.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
            appendBinding(FieldBinding(descriptor: nameField, get: { name.stringValue }, set: { name.stringValue = $0 }))
            rows.append(row(label: "Name", key: "name", control: combined, comment: nil))
        }

        // Endpoint
        if let endpointField = section.fields.first(where: { $0.key == "endpoint" }) {
            let text = NSTextField()
            styleEditableField(text)
            text.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
            appendBinding(FieldBinding(descriptor: endpointField, get: { text.stringValue }, set: { text.stringValue = $0 }))
            rows.append(row(label: "Endpoint", key: "endpoint", control: text, comment: nil))
        }

        // API Key
        if let apiKeyField = section.fields.first(where: { $0.key == "api_key" }) {
            let text = NSSecureTextField()
            styleEditableField(text)
            text.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
            appendBinding(FieldBinding(descriptor: apiKeyField, get: { text.stringValue }, set: { text.stringValue = $0 }))
            rows.append(row(label: "API Key", key: "api_key", control: text, comment: nil))
        }

        // Selected model + Fetch
        if let modelField = section.fields.first(where: { $0.key == "selected-model" }) {
            let combo = llmModelCombo
            styleEditableCombo(combo)
            combo.completes = true
            combo.numberOfVisibleItems = 14
            combo.widthAnchor.constraint(equalToConstant: fieldWidth - actionButtonWidth - 8).isActive = true
            llmFetchButton.title = "Fetch"
            llmFetchButton.bezelStyle = .rounded
            llmFetchButton.controlSize = .regular
            llmFetchButton.target = self
            llmFetchButton.action = #selector(fetchLLMModels)
            llmFetchButton.toolTip = "Fetch Models from /v1/models"
            llmFetchButton.widthAnchor.constraint(equalToConstant: actionButtonWidth).isActive = true
            noteStyle(llmFetchNote)
            let combined = hstack([combo, llmFetchButton], spacing: 8)
            combined.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
            appendBinding(FieldBinding(descriptor: modelField, get: { combo.stringValue }, set: { combo.stringValue = $0 }))
            rows.append(row(label: "Model", key: "selected-model", control: vstack([combined, llmFetchNote]), comment: nil))
        }

        // Context Length + Temperature + Thinking
        if let contextField = section.fields.first(where: { $0.key == "contextLength" }) {
            let context = NSTextField()
            let temperature = NSTextField()
            let thinking = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            styleEditableField(context)
            styleEditableField(temperature)
            context.widthAnchor.constraint(equalToConstant: 88).isActive = true
            temperature.widthAnchor.constraint(equalToConstant: 56).isActive = true
            if let temperatureField = section.fields.first(where: { $0.key == "temperature" }) {
                appendBinding(FieldBinding(
                    descriptor: temperatureField,
                    get: { temperature.stringValue },
                    set: { temperature.stringValue = $0 }
                ))
            }
            if let thinkingField = section.fields.first(where: { $0.key == "thinking" }) {
                appendBinding(FieldBinding(
                    descriptor: thinkingField,
                    get: { thinking.state == .on ? "true" : "false" },
                    set: {
                        thinking.state = ["true", "1", "yes", "on"].contains($0.lowercased()) ? .on : .off
                    }
                ))
            }
            let temperatureLabel = NSTextField(labelWithString: "Temperature")
            temperatureLabel.font = Self.fieldFont
            temperatureLabel.textColor = .secondaryLabelColor
            let thinkingLabel = NSTextField(labelWithString: "Thinking")
            thinkingLabel.font = Self.fieldFont
            thinkingLabel.textColor = .secondaryLabelColor
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let combined = hstack([
                context,
                spacer,
                temperatureLabel,
                temperature,
                thinkingLabel,
                thinking
            ], spacing: 8)
            combined.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
            appendBinding(FieldBinding(descriptor: contextField, get: { context.stringValue }, set: { context.stringValue = $0 }))
            rows.append(row(label: "Context Length", key: "contextLength", control: combined, comment: nil))
        }

        // System prompt
        if let systemField = section.fields.first(where: { $0.key == "system" }) {
            let text = NSTextField()
            text.usesSingleLineMode = false
            text.cell?.wraps = true
            text.cell?.isScrollable = false
            styleEditableField(text)
            text.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
            text.heightAnchor.constraint(equalToConstant: 64).isActive = true
            appendBinding(FieldBinding(descriptor: systemField, get: { text.stringValue }, set: { text.stringValue = $0 }))
            rows.append(row(label: "System Prompt", key: "system", control: text, comment: nil))
        }

        // Test + Status-style result
        llmTestButton.title = "Test"
        llmTestButton.bezelStyle = .rounded
        llmTestButton.controlSize = .regular
        llmTestButton.target = self
        llmTestButton.action = #selector(testLLM)
        llmTestButton.widthAnchor.constraint(equalToConstant: actionButtonWidth).isActive = true
        llmSpinner.style = .spinning
        llmSpinner.controlSize = .small
        llmSpinner.isDisplayedWhenStopped = false
        llmTestResult.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        llmTestResult.textColor = .secondaryLabelColor
        llmTestResult.isSelectable = true
        llmTestResult.alignment = .left
        llmTestResult.maximumNumberOfLines = 2
        llmTestResult.usesSingleLineMode = false
        llmTestResult.lineBreakMode = .byWordWrapping
        llmTestResult.cell?.wraps = true
        llmTestResult.preferredMaxLayoutWidth = fieldWidth
        llmTestResult.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        let testStack = vstack([
            hstack([llmTestButton, llmSpinner], spacing: 8),
            llmTestResult
        ], spacing: 6)
        testStack.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
        rows.append(row(label: "Test", key: nil, control: testStack, comment: nil))

        return scrollWrap(rows)
    }

    private func readLLMEditor() -> LLMServerConfig {
        var scratch = baseConfig
        scratch.webui.llm = LLMServerConfig()
        for binding in llmBindings {
            ConfigStore.apply(section: binding.descriptor.section, key: binding.descriptor.key, value: binding.get(), to: &scratch)
        }
        return scratch.webui.llm
    }

    private func writeLLMEditor(_ profile: LLMServerConfig) {
        var scratch = baseConfig
        scratch.webui.llm = profile
        for binding in llmBindings {
            binding.set(ConfigStore.displayValue(section: binding.descriptor.section, key: binding.descriptor.key, in: scratch))
        }
        // Config only stores selected-model. Until Fetch, the dropdown shows that one name.
        applyLLMModelList([], selected: profile.selectedModel)
        llmFetchNote.stringValue = ""
        llmTestResult.stringValue = ""
        llmTestResult.textColor = .secondaryLabelColor
    }

    /// Replace the Model combo items and keep `selected` as the visible choice.
    /// Empty `models` → dropdown only contains the active selected-model (if any).
    private func applyLLMModelList(_ models: [String], selected: String) {
        let chosen = Self.trim(selected)
        var items = models
        if items.isEmpty {
            if !chosen.isEmpty { items = [chosen] }
        } else if !chosen.isEmpty, !items.contains(chosen) {
            items.insert(chosen, at: 0)
        }
        llmModelCombo.removeAllItems()
        llmModelCombo.addItems(withObjectValues: items)
        llmModelCombo.stringValue = chosen
    }

    /// Base URL without a trailing /v1 (callers append /v1/...).
    private static func llmBase(_ endpoint: String) -> String? {
        guard var base = RemoteWhisperSettings.normalize(endpoint) else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v1") { base.removeLast(3) }
        return base
    }

    @objc private func fetchLLMModels() {
        let profile = readLLMEditor()
        // Capture before the async fetch / combo rebuild so removeAllItems cannot wipe it.
        let selectedBeforeFetch = Self.trim(profile.selectedModel)
        guard let base = Self.llmBase(profile.endpoint) else {
            llmFetchNote.stringValue = "Enter an endpoint first."
            return
        }
        llmFetchButton.isEnabled = false
        llmFetchNote.stringValue = "Fetching models from \(base)/v1/models…"
        let target = RemoteASRTarget(endpoint: base, protocolKind: .openAITranscriptions, model: "",
                                     apiKey: profile.apiKey, auth: collectConfig().webui.auth)
        Task { @MainActor in
            let list = await BackendClient().listRemoteModels(target: target)
            llmFetchButton.isEnabled = true
            guard list.detectedProtocol == .openAITranscriptions, !list.models.isEmpty else {
                // Nothing usable → clear the ephemeral dropdown (and selection). Config still only stores selected-model on Save.
                applyLLMModelList([], selected: "")
                llmFetchNote.stringValue = "No /v1/models list. " + list.note
                Logger.shared.log("Settings: LLM fetch cleared models profile=\(profile.name), endpoint=\(base)")
                return
            }
            // Ephemeral dropdown only — not written to config.json. Keep the model selected when Fetch started.
            applyLLMModelList(list.models, selected: selectedBeforeFetch)
            llmFetchNote.stringValue = "\(list.models.count) models from \(base)/v1/models."
            Logger.shared.log("Settings: fetched LLM models profile=\(profile.name), endpoint=\(base), count=\(list.models.count), kept=\(selectedBeforeFetch)")
        }
    }

    @objc private func testLLM() {
        let profile = readLLMEditor()
        guard let base = Self.llmBase(profile.endpoint), let url = URL(string: base + "/v1/chat/completions") else {
            Self.show("Enter an endpoint first.", ok: false, in: llmTestResult)
            return
        }
        guard !profile.selectedModel.isEmpty else {
            Self.show("Choose a model first (Fetch Models).", ok: false, in: llmTestResult)
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !profile.apiKey.isEmpty {
            request.setValue("Bearer \(profile.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": profile.selectedModel,
            "messages": [["role": "user", "content": "Reply with the single word: OK"]],
            "max_tokens": 32,
            "temperature": 0,
            "stream": false
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        llmTestButton.isEnabled = false
        llmSpinner.startAnimation(nil)
        Self.show("Testing \(profile.selectedModel) at \(base)…", ok: nil, in: llmTestResult)
        Task { @MainActor in
            let started = Date()
            var ok = false
            var line: String
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let seconds = String(format: "%.2f", Date().timeIntervalSince(started))
                if (200..<300).contains(status) {
                    ok = true
                    var reply = ""
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let choices = json["choices"] as? [[String: Any]],
                       let message = choices.first?["message"] as? [String: Any] {
                        reply = (message["content"] as? String) ?? (message["reasoning_content"] as? String) ?? ""
                    }
                    reply = Self.trim(reply)
                    line = "✓ HTTP \(status) in \(seconds) s" + (reply.isEmpty ? " (empty reply)" : ": “\(reply.prefix(120))”")
                } else {
                    let detail = String(data: data, encoding: .utf8) ?? ""
                    line = "✗ HTTP \(status) in \(seconds) s – \(detail.prefix(200))"
                }
            } catch {
                line = "✗ \(error.localizedDescription)"
            }
            Logger.shared.log("Settings: LLM test profile=\(profile.name), endpoint=\(base), model=\(profile.selectedModel), ok=\(ok)")
            llmSpinner.stopAnimation(nil)
            llmTestButton.isEnabled = true
            Self.show(line, ok: ok, in: llmTestResult)
        }
    }

    // MARK: - Behavior pane (hotkey/cues + voice prefs)

    private static let recordingLanguageOptions: [(title: String, mode: String)] = [
        ("Traditional Chinese", "zh-tw"),
        ("Simplified Chinese", "zh-cn"),
        ("English", "en"),
        ("Auto Detect – Traditional", "auto-tw"),
        ("Auto Detect – Simplified", "auto-cn")
    ]

    private func buildRecordingTab(_ section: ConfigSectionDescriptor) -> NSView {
        recordingBackendPopup.removeAllItems()
        recordingBackendPopup.font = Self.fieldFont
        recordingBackendPopup.target = self
        recordingBackendPopup.action = #selector(recordingBackendChanged)
        for (title, value) in [("Local", "local"), ("Remote", "remote")] {
            recordingBackendPopup.addItem(withTitle: title)
            recordingBackendPopup.lastItem?.representedObject = value
        }
        recordingBackendPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        recordingLocalModelPopup.removeAllItems()
        recordingLocalModelPopup.font = Self.fieldFont
        for kind in ASREngineKind.localCases {
            recordingLocalModelPopup.addItem(withTitle: kind.title)
            recordingLocalModelPopup.lastItem?.representedObject = kind.rawValue
        }
        recordingLocalModelPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

        recordingRemoteEndpointPopup.removeAllItems()
        recordingRemoteEndpointPopup.font = Self.fieldFont
        recordingRemoteEndpointPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        noteStyle(recordingRemoteEndpointNote)

        recordingLanguagePopup.removeAllItems()
        recordingLanguagePopup.font = Self.fieldFont
        for option in Self.recordingLanguageOptions {
            recordingLanguagePopup.addItem(withTitle: option.title)
            recordingLanguagePopup.lastItem?.representedObject = option.mode
        }
        recordingLanguagePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

        noteStyle(recordingLiveTypingNote)

        // One fixed-height detail row swaps Local Model ↔ Remote Endpoint so Language does not jump.
        recordingDetailLabel.alignment = .right
        recordingDetailLabel.font = Self.fieldFont
        recordingDetailLabel.widthAnchor.constraint(equalToConstant: 128).isActive = true
        recordingDetailHost.translatesAutoresizingMaskIntoConstraints = false
        recordingLocalModelPopup.translatesAutoresizingMaskIntoConstraints = false
        recordingRemoteEndpointPopup.translatesAutoresizingMaskIntoConstraints = false
        recordingDetailHost.subviews.forEach { $0.removeFromSuperview() }
        recordingDetailHost.addSubview(recordingLocalModelPopup)
        recordingDetailHost.addSubview(recordingRemoteEndpointPopup)
        NSLayoutConstraint.activate([
            recordingDetailHost.heightAnchor.constraint(equalToConstant: 26),
            recordingDetailHost.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            recordingLocalModelPopup.leadingAnchor.constraint(equalTo: recordingDetailHost.leadingAnchor),
            recordingLocalModelPopup.centerYAnchor.constraint(equalTo: recordingDetailHost.centerYAnchor),
            recordingRemoteEndpointPopup.leadingAnchor.constraint(equalTo: recordingDetailHost.leadingAnchor),
            recordingRemoteEndpointPopup.centerYAnchor.constraint(equalTo: recordingDetailHost.centerYAnchor)
        ])
        let detailControl = vstack([recordingDetailHost, recordingRemoteEndpointNote], spacing: 2)
        let detailRow = NSStackView(views: [recordingDetailLabel, detailControl])
        detailRow.orientation = .horizontal
        detailRow.alignment = .firstBaseline
        detailRow.spacing = 8

        let liveTypingControl = vstack([recordingLiveTypingCheckbox, recordingLiveTypingNote])
        let liveTypingRow = row(label: "Live Typing", key: "live_typing", control: liveTypingControl, comment: nil)
        let llmPolishRow = row(label: "LLM Polish", key: "llm_polish", control: recordingLLMPolishCheckbox, comment: nil)
        let arabicNumeralsRow = row(
            label: "Arabic Numerals",
            key: "arabic_numerals",
            control: recordingArabicNumeralsCheckbox,
            comment: nil
        )
        let taiwanPhrasesRow = row(
            label: "Taiwan Phrases",
            key: "taiwan_phrases",
            control: recordingTaiwanPhrasesCheckbox,
            comment: nil
        )
        recordingLiveTypingRow = liveTypingRow
        recordingLLMPolishRow = llmPolishRow
        recordingArabicNumeralsRow = arabicNumeralsRow
        recordingTaiwanPhrasesRow = taiwanPhrasesRow

        let tab = buildCustomSectionTab(
            section,
            overrides: [
                "hotkey_press_count": { [unowned self] field in
                    let pressPopup = NSPopUpButton()
                    pressPopup.font = Self.fieldFont
                    pressPopup.addItems(withTitles: field.options.isEmpty ? ["single", "double"] : field.options)

                    let triggerPopup = NSPopUpButton()
                    triggerPopup.font = Self.fieldFont
                    // Auto first so a failed/uninitialized selection does not stick on a single key.
                    // Option and Alt are the same physical key on macOS (keycode 61).
                    let triggerChoices: [(title: String, value: String)] = [
                        ("Auto", "auto"),
                        ("Ctrl", "right_ctrl"),
                        ("Option / Alt", "right_option"),
                        ("Command", "right_command")
                    ]
                    for choice in triggerChoices {
                        triggerPopup.addItem(withTitle: choice.title)
                        triggerPopup.lastItem?.representedObject = choice.value
                    }

                    let cues = NSButton(checkboxWithTitle: "Play Cues", target: nil, action: nil)
                    cues.font = Self.fieldFont

                    if let triggerField = section.fields.first(where: { $0.key == "hotkey_trigger" }) {
                        self.sectionBindings.append(FieldBinding(
                            descriptor: triggerField,
                            get: { (triggerPopup.selectedItem?.representedObject as? String) ?? "auto" },
                            set: { value in
                                let normalized: String
                                switch value.lowercased() {
                                case "right_ctrl", "right-ctrl", "rightcontrol", "right_control", "ctrl":
                                    normalized = "right_ctrl"
                                case "right_option", "right-option", "rightoption", "option",
                                     "right_alt", "right-alt", "rightalt", "alt":
                                    // Legacy right_alt configs map onto the same Option / Alt choice.
                                    normalized = "right_option"
                                case "right_command", "right-command", "rightcommand", "right_cmd",
                                     "right-cmd", "command", "cmd", "win", "windows":
                                    normalized = "right_command"
                                default:
                                    // "auto", legacy "both", and unknowns.
                                    normalized = "auto"
                                }
                                if let index = triggerPopup.itemArray.firstIndex(where: {
                                    ($0.representedObject as? String) == normalized
                                }) {
                                    triggerPopup.selectItem(at: index)
                                }
                            }
                        ))
                    }
                    if let cuesField = section.fields.first(where: { $0.key == "play_cues" }) {
                        self.sectionBindings.append(FieldBinding(
                            descriptor: cuesField,
                            get: { cues.state == .on ? "true" : "false" },
                            set: {
                                cues.state = ["true", "1", "yes", "on"].contains($0.lowercased()) ? .on : .off
                            }
                        ))
                    }

                    let combined = self.hstack([pressPopup, triggerPopup, cues], spacing: 8)
                    let binding = FieldBinding(
                        descriptor: field,
                        get: { pressPopup.titleOfSelectedItem ?? "single" },
                        set: { value in
                            if pressPopup.item(withTitle: value) == nil, !value.isEmpty {
                                pressPopup.addItem(withTitle: value)
                            }
                            pressPopup.selectItem(withTitle: value)
                        }
                    )
                    return (combined, binding)
                }
            ],
            extraRows: [
                row(label: "ASR Engine", key: "asr_backend", control: recordingBackendPopup, comment: nil),
                detailRow,
                row(label: "Language", key: "chinese_mode", control: recordingLanguagePopup, comment: nil),
                liveTypingRow,
                llmPolishRow,
                arabicNumeralsRow,
                taiwanPhrasesRow
            ],
            skipKeys: ["hotkey_trigger", "play_cues"],
            // Title already shows `[localapp.recording]` via leaf.configPath.
            showSectionHeader: false
        )
        // Rows exist only after this builder runs; sync Local/Remote visibility now.
        updateRecordingBackendUI()
        return tab
    }

    private func loadRecordingPrefs(config: AirTypeConfig, remoteActive: Bool) {
        selectPopup(recordingBackendPopup, represented: remoteActive ? "remote" : "local")
        selectPopup(recordingLocalModelPopup, represented: ASREngineKind.storedLocalModel.rawValue)
        refreshRecordingRemoteEndpoints(selected: RemoteWhisperSettings.selectedEndpoint)
        let language = config.chineseMode.mode
        if recordingLanguagePopup.itemArray.contains(where: { ($0.representedObject as? String) == language }) {
            selectPopup(recordingLanguagePopup, represented: language)
        } else {
            selectPopup(recordingLanguagePopup, represented: "zh-tw")
        }
        recordingLiveTypingCheckbox.state = (UserDefaults.standard.object(forKey: Self.liveTypingDefaultsKey) as? Bool ?? true) ? .on : .off
        recordingLLMPolishCheckbox.state = TextPolisher.enabled ? .on : .off
        recordingArabicNumeralsCheckbox.state = ChineseNumerals.enabled ? .on : .off
        let openCCAvailable = TranscriptFormatter.openCCPath != nil
        recordingTaiwanPhrasesCheckbox.isEnabled = openCCAvailable
        recordingTaiwanPhrasesCheckbox.state = (TranscriptFormatter.useOpenCC && openCCAvailable) ? .on : .off
        recordingTaiwanPhrasesCheckbox.toolTip = openCCAvailable ? nil : "OpenCC is not installed."
        updateRecordingBackendUI()
    }

    private func refreshRecordingRemoteEndpoints(selected: String) {
        recordingRemoteEndpointPopup.removeAllItems()
        let endpoints = RemoteWhisperSettings.endpoints
        if endpoints.isEmpty {
            let empty = NSMenuItem(title: "No Server Configured", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recordingRemoteEndpointPopup.menu?.addItem(empty)
            recordingRemoteEndpointNote.stringValue = "Add an endpoint under Endpoint Profiles ▸ ASR Endpoints."
        } else {
            for endpoint in endpoints {
                recordingRemoteEndpointPopup.addItem(withTitle: endpoint)
                recordingRemoteEndpointPopup.lastItem?.representedObject = endpoint
            }
            if !selected.isEmpty {
                selectPopup(recordingRemoteEndpointPopup, represented: selected)
            } else if let first = endpoints.first {
                selectPopup(recordingRemoteEndpointPopup, represented: first)
            }
            recordingRemoteEndpointNote.stringValue = ""
        }
    }

    private func selectPopup(_ popup: NSPopUpButton, represented: String) {
        if let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == represented }) {
            popup.selectItem(at: index)
        }
    }

    private var recordingBackendIsRemote: Bool {
        (recordingBackendPopup.selectedItem?.representedObject as? String) == "remote"
    }

    @objc private func recordingBackendChanged() {
        updateRecordingBackendUI()
    }

    private func updateRecordingBackendUI() {
        let remote = recordingBackendIsRemote
        remoteEngineActive = remote
        recordingDetailLabel.stringValue = remote ? "Remote Endpoint" : "Local Model"
        recordingLocalModelPopup.isHidden = remote
        recordingRemoteEndpointPopup.isHidden = !remote
        // Keep note slot stable: hide when Local, or when Remote has nothing to say.
        let note = recordingRemoteEndpointNote.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        recordingRemoteEndpointNote.isHidden = !remote || note.isEmpty
        // Local-only vs Remote-only preference rows (NSStackView detaches hidden views).
        recordingLiveTypingRow?.isHidden = remote
        recordingLiveTypingNote.stringValue = ""
        recordingLLMPolishRow?.isHidden = !remote
        recordingArabicNumeralsRow?.isHidden = !remote
        recordingTaiwanPhrasesRow?.isHidden = !remote
    }

    private func persistRecordingRuntimePrefs() {
        let remote = recordingBackendIsRemote
        remoteEngineActive = remote
        ASREngineKind.persistBackend(remote: remote)
        if remote {
            if let endpoint = recordingRemoteEndpointPopup.selectedItem?.representedObject as? String,
               !endpoint.isEmpty {
                RemoteWhisperSettings.select(endpoint)
            }
        } else if let raw = recordingLocalModelPopup.selectedItem?.representedObject as? String,
                  let kind = ASREngineKind(rawValue: raw) {
            ASREngineKind.persistLocalModel(kind)
        }
        UserDefaults.standard.set(recordingLiveTypingCheckbox.state == .on, forKey: Self.liveTypingDefaultsKey)
        UserDefaults.standard.set(recordingLLMPolishCheckbox.state == .on, forKey: TextPolisher.defaultsKey)
        UserDefaults.standard.set(recordingArabicNumeralsCheckbox.state == .on, forKey: ChineseNumerals.defaultsKey)
        if TranscriptFormatter.openCCPath != nil {
            UserDefaults.standard.set(recordingTaiwanPhrasesCheckbox.state == .on, forKey: TranscriptFormatter.openCCDefaultsKey)
        }
    }

    private func recordingLanguageMode() -> String {
        (recordingLanguagePopup.selectedItem?.representedObject as? String)
            ?? baseConfig.chineseMode.mode
    }

    // MARK: - Microphone pane (live device list)

    private func buildMicrophoneTab(_ section: ConfigSectionDescriptor) -> NSView {
        buildCustomSectionTab(section, overrides: [
            "selected_device_name": { [unowned self] field in
                self.micDevicePopup.target = self
                self.micDevicePopup.action = #selector(self.micDeviceChanged)
                self.micDevicePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
                let refresh = NSButton(title: "Refresh", target: self, action: #selector(self.refreshMicDevicesClicked))
                refresh.bezelStyle = .rounded
                self.noteStyle(self.micDeviceNote)
                let control = self.vstack([self.hstack([self.micDevicePopup, refresh]), self.micDeviceNote])
                let binding = FieldBinding(
                    descriptor: field,
                    get: { [unowned self] in self.micSelectedName },
                    set: { [unowned self] value in
                        self.micSelectedName = value
                        self.refreshMicDevices(force: true)
                    }
                )
                return (control, binding)
            }
        ])
    }

    private func installDeviceObservers() {
        let center = NotificationCenter.default
        let refresh: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.refreshMicDevices(force: false) }
        }
        micObservers = [
            center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main, using: refresh),
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main, using: refresh),
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: refresh)
        ]
    }

    /// While the window is open, re-scan every 2 s when the Microphone pane is showing
    /// (device notifications are not posted for every Core Audio change).
    private func startMicTimer() {
        guard micTimer == nil else { return }
        micTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window?.isVisible == true,
                      self.selectedLeaf?.sections.contains(Self.microphoneTabID) == true else { return }
                self.refreshMicDevices(force: false)
            }
        }
    }

    @objc private func refreshMicDevicesClicked() {
        refreshMicDevices(force: true)
    }

    @objc private func micDeviceChanged() {
        micSelectedName = micDevicePopup.selectedItem?.representedObject as? String ?? ""
        micDeviceNote.stringValue = ""
    }

    /// Rebuilds the device popup from AudioRecorder.inputDevices(), keeping the selected name.
    /// Only `selected_device_name` is touched; other microphone fields keep their edits.
    private func refreshMicDevices(force: Bool) {
        let devices = AudioRecorder.inputDevices()
        let signature = devices.map { "\($0.uniqueID)|\($0.localizedName)" } + ["selected:\(micSelectedName)"]
        if !force, signature == micDeviceSignature { return }
        let changed = !micDeviceSignature.isEmpty && signature != micDeviceSignature
        micDeviceSignature = signature

        guard let menu = micDevicePopup.menu else { return }
        menu.removeAllItems()
        let defaultItem = NSMenuItem(title: "System Default", action: nil, keyEquivalent: "")
        defaultItem.representedObject = ""
        menu.addItem(defaultItem)
        if !devices.isEmpty { menu.addItem(.separator()) }
        var selectedItem: NSMenuItem? = micSelectedName.isEmpty ? defaultItem : nil
        for device in devices {
            let item = NSMenuItem(title: device.localizedName, action: nil, keyEquivalent: "")
            item.representedObject = device.localizedName
            item.toolTip = device.uniqueID
            menu.addItem(item)
            if selectedItem == nil, device.localizedName == micSelectedName { selectedItem = item }
        }
        if selectedItem == nil {
            menu.addItem(.separator())
            let missing = NSMenuItem(title: "\(micSelectedName) (not connected)", action: nil, keyEquivalent: "")
            missing.representedObject = micSelectedName
            menu.addItem(missing)
            selectedItem = missing
        }
        micDevicePopup.select(selectedItem)

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let connected = micSelectedName.isEmpty || devices.contains(where: { $0.localizedName == micSelectedName })
        micDeviceNote.stringValue = ""
            + (changed ? " · device list changed" : "")
            + " · refreshed \(formatter.string(from: Date()))"
            + (connected ? "" : " · selected device is not connected (falls back to System Default)")
        if changed {
            Logger.shared.log("Settings: microphone device list changed: \(devices.map(\.localizedName).joined(separator: ", "))")
        }
    }

    // MARK: - Obsidian pane

    private func buildObsidianTab(_ section: ConfigSectionDescriptor) -> NSView {
        buildCustomSectionTab(section, overrides: [
            "vault_path": { [unowned self] field in
                let text = self.obsidianVaultField
                self.styleEditableField(text)
                text.widthAnchor.constraint(equalToConstant: 400).isActive = true
                text.placeholderString = ""
                let browse = NSButton(title: "Browse…", target: self, action: #selector(self.browseObsidianVault))
                browse.bezelStyle = .rounded
                let binding = FieldBinding(descriptor: field, get: { text.stringValue }, set: { text.stringValue = $0 })
                return (self.hstack([text, browse]), binding)
            }
        ])
    }

    @objc private func browseObsidianVault() {
        chooseDirectory(startingAt: obsidianVaultField.stringValue, message: "Choose the Obsidian vault folder AirType writes notes into") { [weak self] path in
            guard let self else { return }
            self.applyBrowsedPath(path, to: self.obsidianVaultField)
        }
    }

    // MARK: - History panes

    private func buildVoiceHistoryTab() -> NSView {
        let pane = HistorySettingsPaneController(kind: .voice)
        voiceHistoryPane = pane
        return pane.makeView()
    }

    private func buildObsidianHistoryTab() -> NSView {
        let pane = HistorySettingsPaneController(kind: .obsidian)
        obsidianHistoryPane = pane
        return pane.makeView()
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
        config.chineseMode.mode = recordingLanguageMode()
        // Profiles: saved lists with pending form edits folded into the selected profile.
        let llm = llmSession.committed()
        if let selected = llm.selected {
            // Persist only selected-model per profile; supported-model catalogs are Fetch-time UI state.
            // The highlighted profile becomes the one the app uses (default-llm-server-name).
            config.webui.llmServers = llm.profiles.map { profile in
                var profile = profile
                profile.models = []
                return profile
            }
            var selectedProfile = selected
            selectedProfile.models = []
            config.webui.selectedServerName = selectedProfile.name
            config.webui.llm = selectedProfile
            config.webui.selectedModelName = selectedProfile.selectedModel
        }
        let asr = asrSession.committed()
        let asrProfiles = asr.profiles.map { profile -> RemoteASRConfig in
            var profile = profile
            profile.endpoint = RemoteWhisperSettings.normalize(profile.endpoint) ?? ""
            return profile
        }
        if let selected = asrProfiles.first(where: { $0.name == asr.selectedName }) ?? asrProfiles.first {
            config.remoteASRProfiles = asrProfiles
            config.remoteASR = selected
            config.selectedRemoteASRName = selected.name
        }
        let whisper = whisperSession.committed()
        if let selected = whisper.selected {
            config.webui.whisperServers = whisper.profiles
            config.webui.whisper = selected
            config.webui.selectedWhisperServerName = selected.name
        }
        return config
    }

    @discardableResult
    private func commit() -> Bool {
        let config = collectConfig()
        let effectiveEndpoint = config.remoteASR.endpoint.isEmpty ? (RemoteWhisperSettings.normalize(config.backend.remoteEndpoint) ?? "") : config.remoteASR.endpoint
        if remoteEngineActive, effectiveEndpoint.isEmpty {
            select(section: Self.remoteTabID)
            showTestResult("Active ASR profile “\(config.remoteASR.name)” has no endpoint. Fix it.", ok: false)
            NSSound.beep()
            return false
        }
        if remoteEngineActive, config.remoteASR.protocolName == RemoteASRProtocol.openAITranscriptions.rawValue,
           config.remoteASR.model.isEmpty {
            select(section: Self.remoteTabID)
            showTestResult("Active ASR profile “\(config.remoteASR.name)” uses OpenAI Compatible and needs a model.", ok: false)
            NSSound.beep()
            return false
        }
        baseConfig = config
        persistRecordingRuntimePrefs()
        onSave?(config, remoteEngineActive)
        reloadSessions(from: config, keepSelection: true)
        // Endpoint list may change after ASR profile Apply; keep Behavior in sync.
        refreshRecordingRemoteEndpoints(selected: RemoteWhisperSettings.selectedEndpoint)
        updateRecordingBackendUI()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        footerStatus.stringValue = "Saved \(formatter.string(from: Date()))"
        return true
    }

    @objc private func apply() {
        commit()
    }

    @objc private func save() {
        // Persist only — keep Settings open (close via Cancel / window chrome).
        commit()
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


/// Text cell with inner padding so text doesn't touch the outline.
private let fieldInset = NSSize(width: 8, height: 4)

private func paddedRect(_ rect: NSRect, font: NSFont?, singleLine: Bool) -> NSRect {
    var r = rect.insetBy(dx: fieldInset.width, dy: 0)
    if singleLine, let font {
        let lineH = ceil(font.ascender - font.descender + font.leading)
        r.origin.y = rect.origin.y + max(0, (rect.height - lineH) / 2)
        r.size.height = lineH
    } else {
        r = r.insetBy(dx: 0, dy: fieldInset.height)
    }
    return r
}

final class PaddedTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        paddedRect(super.drawingRect(forBounds: rect), font: font, singleLine: usesSingleLineMode)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

final class PaddedSecureTextFieldCell: NSSecureTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        paddedRect(super.drawingRect(forBounds: rect), font: font, singleLine: usesSingleLineMode)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}
