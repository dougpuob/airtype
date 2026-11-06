import AVFoundation
import AppKit
import Foundation

/// Settings window: left sidebar with Local Service / Endpoints / UI / External groups (NSOutlineView) and a detail pane on the right.
/// Each leaf maps to a section of ~/.airtype-experiment/config.toml; Apply / Save writes config.toml through
/// ConfigStore and the coordinator reloads it in-app.
///
/// Endpoints (ASR, Whisper, LLM) are profile lists: [[localapp.remote-asr]], [[webui.whisper-server]] and
/// [[webui.llm-server]], each with a `name` and an active-profile key
/// ([localapp] default-remote-asr-name, [webui] default-whisper-server-name, [webui] default-llm-server-name).
/// Local Service ([localapp.local-whisper]) holds the self-hosted whisper-server settings, separate from endpoint profiles.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let remoteTabID = "localapp.remote-asr"
    static let whisperTabID = "webui.whisper-server"
    static let llmTabID = "webui.llm-server"
    static let microphoneTabID = "localapp.microphone"
    static let localWhisperTabID = "localapp.local-whisper"

    /// (new config, use Remote ASR as the active engine)
    var onSave: ((AirTypeConfig, Bool) -> Void)?

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
        /// config.toml section ids shown in this pane (used to route `present(tab:)`).
        let sections: [String]
        let view: NSView
        init(title: String, sections: [String], view: NSView) {
            self.title = title
            self.sections = sections
            self.view = view
        }
    }
    private var groups: [SidebarGroup] = []
    private let sidebarOutline = NSOutlineView()
    private let detailContainer = NSView()
    private let detailTitle = NSTextField(labelWithString: "")
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
    private let whisperModelDirField = NSTextField()
    private let whisperModelCombo = NSComboBox()
    private let whisperModelNote = NSTextField(wrappingLabelWithString: "")
    private let localTestButton = NSButton()
    private let localSpinner = NSProgressIndicator()
    private let localTestResult = NSTextField(wrappingLabelWithString: "")

    // LLM form
    private var llmBindings: [FieldBinding] = []
    private let llmModelsField = NSTextField()
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

    // Obsidian
    private let obsidianVaultField = NSTextField()

    private let footerStatus = NSTextField(labelWithString: "")

    init(configPath: String) {
        self.configPath = configPath
        super.init()
    }

    // MARK: - Presenting

    /// `tab` is a config.toml section id (e.g. `localapp.remote-asr`, `webui.llm-server`, `webui.auth`).
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
        localTestResult.stringValue = ""
        remoteEngineActive = remoteActive
        footerStatus.stringValue = ""
        refreshMicDevices(force: true)
    }

    private func reloadSessions(from config: AirTypeConfig, keepSelection: Bool) {
        asrSession.load(
            config.remoteASRProfiles.isEmpty ? [config.remoteASR] : config.remoteASRProfiles,
            activeName: config.selectedRemoteASRName.isEmpty ? config.remoteASR.name : config.selectedRemoteASRName,
            selecting: keepSelection ? asrSession.index : nil
        )
        whisperSession.load(
            config.webui.whisperServers.isEmpty ? [config.webui.whisper] : config.webui.whisperServers,
            activeName: config.webui.selectedWhisperServerName.isEmpty ? config.webui.whisper.name : config.webui.selectedWhisperServerName,
            selecting: keepSelection ? whisperSession.index : nil
        )
        llmSession.load(
            config.webui.llmServers.isEmpty ? [config.webui.llm] : config.webui.llmServers,
            activeName: config.webui.selectedServerName.isEmpty ? config.webui.llm.name : config.webui.selectedServerName,
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
        detailTitle.translatesAutoresizingMaskIntoConstraints = false
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
        content.addSubview(detailTitle)
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

            detailTitle.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            detailTitle.leadingAnchor.constraint(equalTo: separator.trailingAnchor, constant: 20),
            detailTitle.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            detailContainer.topAnchor.constraint(equalTo: detailTitle.bottomAnchor, constant: 8),
            detailContainer.leadingAnchor.constraint(equalTo: separator.trailingAnchor, constant: 12),
            detailContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            footer.topAnchor.constraint(equalTo: detailContainer.bottomAnchor, constant: 10),
            footer.leadingAnchor.constraint(equalTo: separator.trailingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
        window.contentView = content
        self.window = window
        sidebarOutline.reloadData()
        for group in groups {
            sidebarOutline.expandItem(group, expandChildren: false)
        }
    }

    /// Sidebar groups and leaves, in display order. Each leaf is built from its config.toml section(s).
    private func buildCategories() {
        let descriptors = Dictionary(ConfigStore.sectionDescriptors.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        func leaf(_ title: String, _ id: String, extraSections: [String] = [], builder: (ConfigSectionDescriptor) -> NSView) -> SidebarLeaf? {
            guard let section = descriptors[id] else { return nil }
            return SidebarLeaf(title: title, sections: [id] + extraSections, view: builder(section))
        }

        // Local Service: self-hosted servers on this Mac. Endpoints: ASR / Whisper / LLM profile lists + backend.
        // UI: appearance & auth. External: mic & integrations.
        // [localapp] / [webui] only hold the active-profile names, which live on the ASR / Whisper / LLM pages.
        let localServiceLeaves: [SidebarLeaf] = [
            leaf("Whisper Server", Self.localWhisperTabID, builder: buildLocalWhisperTab)
        ].compactMap { $0 }

        var endpointLeaves: [SidebarLeaf] = [
            leaf("ASR Endpoints", Self.remoteTabID, extraSections: ["localapp"], builder: buildRemoteTab),
            leaf("LLM Endpoints", Self.llmTabID, extraSections: ["webui"], builder: buildLLMTab),
            leaf("Whisper Endpoints", Self.whisperTabID, builder: buildWhisperTab)
        ].compactMap { $0 }

        let uiLeaves: [SidebarLeaf] = [
            leaf("Floating Pill", "localapp.floating-dialog", builder: buildSectionTab)
        ].compactMap { $0 }

        var externalLeaves: [SidebarLeaf] = [
            leaf("Microphone", Self.microphoneTabID, builder: buildMicrophoneTab),
            leaf("Obsidian", "localapp.obsidian", builder: buildObsidianTab)
        ].compactMap { $0 }

        // Any leftover sectionDescriptors stay reachable (do not drop tabs).
        let hiddenSections: Set<String> = ["localapp.backend-endpoint", "localapp.chinese-mode", "webui.auth"]
        let placed = Set((localServiceLeaves + endpointLeaves + uiLeaves + externalLeaves).flatMap(\.sections)).union(hiddenSections)
        let leftovers = ConfigStore.sectionDescriptors.filter { !placed.contains($0.name) && $0.name != "webui" && $0.name != "localapp" }
        for section in leftovers {
            let connectionLike = section.name.contains("server")
                || section.name.contains("endpoint")
                || section.name.contains("asr")
                || section.name.contains("backend")
            let title = section.name.split(separator: ".").last.map { part -> String in
                part.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            } ?? section.name
            let item = SidebarLeaf(title: title, sections: [section.name], view: buildSectionTab(section))
            if connectionLike {
                endpointLeaves.append(item)
            } else {
                externalLeaves.append(item)
            }
        }

        groups = [
            SidebarGroup(title: "Service Providers", leaves: localServiceLeaves),
            SidebarGroup(title: "Service Connectors", leaves: endpointLeaves),
            SidebarGroup(title: "UI", leaves: uiLeaves),
            SidebarGroup(title: "Others", leaves: externalLeaves)
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
        case "selected-model": return "Selected Model"
        case "default-llm-server-name": return "Default Server"
        case "model_dir": return "Model Dir"
        case "server_bin": return "Server Binary"
        case "server_args": return "Server Args"
        case "model_filename": return "Model"
        case "launch_on_start": return "Launch on App Start"
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
    private func buildCustomSectionTab(_ section: ConfigSectionDescriptor,
                                       overrides: [String: (ConfigFieldDescriptor) -> (NSView, FieldBinding)],
                                       extraRows: [NSView] = []) -> NSView {
        var rows: [NSView] = [sectionHeader("[\(section.name)]")]
        for field in section.fields {
            let (control, binding) = overrides[field.key]?(field) ?? makeControl(field)
            sectionBindings.append(binding)
            rows.append(row(label: Self.fieldLabel(field.key), key: field.key, control: control, comment: field.comment))
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
        name.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let right = NSStackView(views: [control])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 3
        _ = comment
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

    private func chooseDirectory(startingAt path: String, message: String, completion: @escaping (String) -> Void) {
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
            sectionHeader("[[\(section.name)]]  ·  active = [localapp] default-remote-asr-name"),
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
            sectionHeader("[[\(section.name)]]  ·  active = [webui] default-whisper-server-name"),
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
        let testStack = setupTestControls(button: localTestButton, spinner: localSpinner, result: localTestResult, action: #selector(testLocalWhisper))
        localTestButton.title = "Check"
        return buildCustomSectionTab(section, overrides: [
            "server_bin": { [unowned self] field in
                let text = self.localServerBinField
                self.styleEditableField(text)
                text.widthAnchor.constraint(equalToConstant: 380).isActive = true
                text.placeholderString = "whisper-server"
                let browse = NSButton(title: "Browse…", target: self, action: #selector(self.browseLocalServerBin))
                browse.bezelStyle = .rounded
                let binding = FieldBinding(descriptor: field, get: { text.stringValue }, set: { text.stringValue = $0 })
                return (self.hstack([text, browse]), binding)
            },
            "model_dir": { [unowned self] field in
                let text = self.whisperModelDirField
                self.styleEditableField(text)
                text.widthAnchor.constraint(equalToConstant: 380).isActive = true
                text.target = self
                text.action = #selector(self.refreshWhisperModels)
                let browse = NSButton(title: "Browse…", target: self, action: #selector(self.browseWhisperModelDir))
                browse.bezelStyle = .rounded
                let binding = FieldBinding(descriptor: field, get: { text.stringValue }, set: { text.stringValue = $0 })
                return (self.hstack([text, browse]), binding)
            },
            "model_filename": { [unowned self] field in
                let combo = self.whisperModelCombo
                self.styleEditableCombo(combo)
                combo.completes = true
                combo.numberOfVisibleItems = 14
                combo.widthAnchor.constraint(equalToConstant: 380).isActive = true
                let refresh = NSButton(title: "Refresh", target: self, action: #selector(self.refreshWhisperModels))
                refresh.bezelStyle = .rounded
                self.noteStyle(self.whisperModelNote)
                let binding = FieldBinding(descriptor: field, get: { combo.stringValue }, set: { combo.stringValue = $0 })
                return (self.vstack([self.hstack([combo, refresh]), self.whisperModelNote]), binding)
            }
        ], extraRows: [row(label: "Check", key: nil, control: testStack, comment: nil)])
    }

    @objc private func browseLocalServerBin() {
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
            if response == .OK, let url = panel.url { self?.localServerBinField.stringValue = url.path }
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
            self.whisperModelDirField.stringValue = (path as NSString).abbreviatingWithTildeInPath
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

    /// Checks that the binary and model file exist (does not start the server).
    @objc private func testLocalWhisper() {
        let fm = FileManager.default
        var lines: [String] = []
        var ok = true
        let bin = Self.expandPath(localServerBinField.stringValue)
        if bin.isEmpty {
            let found = ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"].first(where: fm.isExecutableFile(atPath:))
            if let found {
                lines.append("✓ server binary: \(found)")
            } else {
                ok = false
                lines.append("✗ whisper-server not found; set Server Binary.")
            }
        } else if fm.isExecutableFile(atPath: bin) {
            lines.append("✓ server binary: \(bin)")
        } else {
            ok = false
            lines.append("✗ not executable: \(bin)")
        }
        let dir = Self.expandPath(whisperModelDirField.stringValue)
        let file = Self.trim(whisperModelCombo.stringValue)
        if dir.isEmpty || file.isEmpty {
            ok = false
            lines.append("✗ set Model Dir and Model.")
        } else {
            let model = (dir as NSString).appendingPathComponent(file)
            if let attributes = try? fm.attributesOfItem(atPath: model), let size = attributes[.size] as? NSNumber {
                lines.append(String(format: "✓ model: %@ (%.0f MB)", model, size.doubleValue / 1_048_576))
            } else {
                ok = false
                lines.append("✗ model not found: \(model)")
            }
        }
        Logger.shared.log("Settings: local whisper check ok=\(ok), result=\(lines.joined(separator: " | "))")
        Self.show(lines.joined(separator: "\n"), ok: ok, in: localTestResult)
    }

    // MARK: - LLM pane ([[webui.llm-server]])

    private func buildLLMTab(_ section: ConfigSectionDescriptor) -> NSView {
        var rows: [NSView] = [
            sectionHeader("[[\(section.name)]]  ·  active = [webui] default-llm-server-name"),
            row(label: "Profiles", key: nil, control: llmSession.panel.view, comment: nil)
        ]
        for field in section.fields {
            let control: NSView
            let binding: FieldBinding
            switch field.key {
            case "models":
                let text = llmModelsField
                styleEditableField(text)
                text.widthAnchor.constraint(equalToConstant: 480).isActive = true
                text.placeholderString = ""
                control = text
                binding = FieldBinding(descriptor: field, get: { text.stringValue }, set: { text.stringValue = $0 })
            case "selected-model":
                let combo = llmModelCombo
                styleEditableCombo(combo)
                combo.completes = true
                combo.numberOfVisibleItems = 14
                combo.widthAnchor.constraint(equalToConstant: 360).isActive = true
                llmFetchButton.title = "Fetch Models"
                llmFetchButton.bezelStyle = .rounded
                llmFetchButton.target = self
                llmFetchButton.action = #selector(fetchLLMModels)
                noteStyle(llmFetchNote)
                control = vstack([hstack([combo, llmFetchButton]), llmFetchNote])
                binding = FieldBinding(descriptor: field, get: { combo.stringValue }, set: { combo.stringValue = $0 })
            default:
                (control, binding) = makeControl(field)
            }
            llmBindings.append(binding)
            rows.append(row(label: Self.fieldLabel(field.key), key: field.key, control: control, comment: nil))
        }
        let testStack = setupTestControls(button: llmTestButton, spinner: llmSpinner, result: llmTestResult, action: #selector(testLLM))
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
        llmModelCombo.removeAllItems()
        llmModelCombo.addItems(withObjectValues: profile.models)
        llmModelCombo.stringValue = profile.selectedModel
        llmFetchNote.stringValue = ""
        llmTestResult.stringValue = ""
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
                llmFetchNote.stringValue = "No /v1/models list. " + list.note
                return
            }
            llmModelsField.stringValue = list.models.joined(separator: ", ")
            llmModelCombo.removeAllItems()
            llmModelCombo.addItems(withObjectValues: list.models)
            let current = Self.trim(llmModelCombo.stringValue)
            if current.isEmpty || !list.models.contains(current) {
                llmModelCombo.stringValue = list.models[0]
            }
            llmFetchNote.stringValue = "\(list.models.count) models from \(base)/v1/models."
            Logger.shared.log("Settings: fetched LLM models profile=\(profile.name), endpoint=\(base), count=\(list.models.count)")
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
            self?.obsidianVaultField.stringValue = path
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
        // Profiles: saved lists with pending form edits folded into the selected profile.
        let llm = llmSession.committed()
        if let active = llm.active {
            config.webui.llmServers = llm.profiles
            config.webui.selectedServerName = active.name
            config.webui.llm = active
            config.webui.selectedModelName = active.selectedModel
        }
        let asr = asrSession.committed()
        let asrProfiles = asr.profiles.map { profile -> RemoteASRConfig in
            var profile = profile
            profile.endpoint = RemoteWhisperSettings.normalize(profile.endpoint) ?? ""
            return profile
        }
        if let active = asrProfiles.first(where: { $0.name == asr.activeName }) ?? asrProfiles.first {
            config.remoteASRProfiles = asrProfiles
            config.remoteASR = active
            config.selectedRemoteASRName = active.name
        }
        let whisper = whisperSession.committed()
        if let active = whisper.active {
            config.webui.whisperServers = whisper.profiles
            config.webui.whisper = active
            config.webui.selectedWhisperServerName = active.name
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
        onSave?(config, remoteEngineActive)
        reloadSessions(from: config, keepSelection: true)
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
