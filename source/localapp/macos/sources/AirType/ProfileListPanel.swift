import AppKit
import Foundation

/// Settings ▸ Endpoints profile list: a table of named profiles (✓ = active) with
/// Add / Modify / Delete / Set Active. The panel only renders and forwards actions;
/// `ProfileSession` owns the data.
@MainActor
final class ProfileListPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view: NSView
    let statusLabel = NSTextField(wrappingLabelWithString: "")

    /// (from, to) → false cancels the selection change.
    var shouldChangeSelection: ((Int, Int) -> Bool)?
    var onSelect: ((Int) -> Void)?
    var onAdd: (() -> Void)?
    var onModify: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSetActive: (() -> Void)?

    private var names: [String] = []
    private var activeName = ""
    private(set) var selectedIndex = 0
    private var suppress = false
    private let table = NSTableView()
    private let activeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("active"))
    private let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))

    override init() {
        let container = NSStackView()
        view = container
        super.init()

        activeColumn.title = "Active"
        activeColumn.width = 48
        activeColumn.minWidth = 48
        activeColumn.maxWidth = 48
        nameColumn.title = "Profile"
        nameColumn.width = 220
        table.addTableColumn(activeColumn)
        table.addTableColumn(nameColumn)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(setActiveClicked)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 4
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor(calibratedWhite: 0.52, alpha: 1).cgColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 300).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 132).isActive = true

        func button(_ title: String, _ action: Selector, _ tip: String) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.toolTip = tip
            b.widthAnchor.constraint(equalToConstant: 110).isActive = true
            return b
        }
        let buttons = NSStackView(views: [
            button("Add", #selector(addClicked), "Save the form below as a new profile."),
            button("Modify", #selector(modifyClicked), "Save the form below into the selected profile."),
            button("Delete", #selector(deleteClicked), "Remove the selected profile."),
            button("Set Active", #selector(setActiveClicked), "Use the selected profile (double-click a row does the same).")
        ])
        buttons.orientation = .vertical
        buttons.alignment = .leading
        buttons.spacing = 6

        let top = NSStackView(views: [scroll, buttons])
        top.orientation = .horizontal
        top.alignment = .top
        top.spacing = 10

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.preferredMaxLayoutWidth = 480

        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6
        container.addArrangedSubview(top)
        container.addArrangedSubview(statusLabel)
    }

    func reload(names: [String], activeName: String, selected: Int) {
        self.names = names
        self.activeName = activeName
        selectedIndex = names.isEmpty ? 0 : min(max(0, selected), names.count - 1)
        suppress = true
        table.reloadData()
        if !names.isEmpty {
            table.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
            table.scrollRowToVisible(selectedIndex)
        }
        suppress = false
    }

    func setStatus(_ text: String, ok: Bool? = nil) {
        statusLabel.stringValue = text
        switch ok {
        case .some(true): statusLabel.textColor = .systemGreen
        case .some(false): statusLabel.textColor = .systemRed
        case .none: statusLabel.textColor = .secondaryLabelColor
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { names.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ProfileCell-\(tableColumn?.identifier.rawValue ?? "")")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
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
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        let isActive = names[row] == activeName
        if tableColumn === activeColumn {
            cell.textField?.stringValue = isActive ? "✓" : ""
            cell.textField?.alignment = .center
        } else {
            cell.textField?.stringValue = names[row]
            cell.textField?.font = isActive ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if suppress || row == selectedIndex { return true }
        return shouldChangeSelection?(selectedIndex, row) ?? true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppress else { return }
        let row = table.selectedRow
        guard row >= 0, row != selectedIndex else { return }
        selectedIndex = row
        onSelect?(row)
    }

    @objc private func addClicked() { onAdd?() }
    @objc private func modifyClicked() { onModify?() }
    @objc private func deleteClicked() { onDelete?() }
    @objc private func setActiveClicked() { onSetActive?() }
}

/// Data + editor glue for one kind of endpoint profile (Remote ASR, Whisper, LLM).
/// Model: the list holds saved profiles; the form below edits a copy of the selected one.
/// Add = form → new profile, Modify = form → selected profile, Delete = remove selected,
/// Set Active = selected profile becomes the one the app uses. Nothing is written to
/// config.json until the window's Apply / Save (which also folds in pending form edits).
@MainActor
final class ProfileSession<Profile: Equatable> {
    let kind: String
    let panel = ProfileListPanel()
    private(set) var profiles: [Profile] = []
    private(set) var activeName = ""
    private(set) var index = 0
    private let nameKey: WritableKeyPath<Profile, String>
    private let readEditor: () -> Profile
    private let writeEditor: (Profile) -> Void

    init(kind: String, name: WritableKeyPath<Profile, String>, readEditor: @escaping () -> Profile, writeEditor: @escaping (Profile) -> Void) {
        self.kind = kind
        nameKey = name
        self.readEditor = readEditor
        self.writeEditor = writeEditor
        panel.shouldChangeSelection = { [unowned self] _, _ in self.confirmLeavingEditor() }
        panel.onSelect = { [unowned self] row in self.select(row) }
        panel.onAdd = { [unowned self] in self.add() }
        panel.onModify = { [unowned self] in _ = self.modify() }
        panel.onDelete = { [unowned self] in self.delete() }
        panel.onSetActive = { [unowned self] in self.setActive() }
    }

    var selectedProfile: Profile? { profiles.indices.contains(index) ? profiles[index] : nil }

    /// `selecting` keeps a row selected (e.g. after Apply); nil selects the active profile.
    func load(_ list: [Profile], activeName: String, selecting: Int? = nil) {
        profiles = list
        self.activeName = list.contains(where: { $0[keyPath: nameKey] == activeName }) ? activeName : (list.first?[keyPath: nameKey] ?? "")
        if let selecting, !list.isEmpty {
            index = min(max(0, selecting), list.count - 1)
        } else {
            index = max(0, list.firstIndex(where: { $0[keyPath: nameKey] == self.activeName }) ?? 0)
        }
        refresh()
        if let selectedProfile { writeEditor(selectedProfile) }
        panel.setStatus("")
    }

    /// Saved profiles with pending form edits folded into the selected one, plus the active profile.
    func committed() -> (profiles: [Profile], active: Profile?, activeName: String) {
        var list = profiles
        var active = activeName
        if list.indices.contains(index) {
            var edited = readEditor()
            let oldName = list[index][keyPath: nameKey]
            let newName = edited[keyPath: nameKey]
            if newName.isEmpty || list.enumerated().contains(where: { $0.offset != index && $0.element[keyPath: nameKey] == newName }) {
                edited[keyPath: nameKey] = oldName
            }
            list[index] = edited
            if active == oldName { active = edited[keyPath: nameKey] }
        }
        let activeProfile = list.first(where: { $0[keyPath: nameKey] == active }) ?? list.first
        return (list, activeProfile, activeProfile?[keyPath: nameKey] ?? "")
    }

    var isEditorDirty: Bool {
        guard let selectedProfile else { return false }
        return readEditor() != selectedProfile
    }

    private func refresh() {
        panel.reload(names: profiles.map { $0[keyPath: nameKey] }, activeName: activeName, selected: index)
    }

    private func statusSummary() -> String {
        "\(profiles.count) profile\(profiles.count == 1 ? "" : "s") · active: \(activeName.isEmpty ? "–" : activeName)"
    }

    private func confirmLeavingEditor() -> Bool {
        guard isEditorDirty, let selectedProfile else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(selectedProfile[keyPath: nameKey])”?"
        alert.informativeText = "The form has edits that were not saved into the \(kind) profile."
        alert.addButton(withTitle: "Modify")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return modify()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    private func select(_ row: Int) {
        guard profiles.indices.contains(row) else { return }
        index = row
        writeEditor(profiles[row])
        panel.setStatus("")
    }

    private func uniqueName(_ base: String) -> String {
        let root = base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "profile" : base.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = root
        var suffix = 2
        while profiles.contains(where: { $0[keyPath: nameKey] == candidate }) { candidate = "\(root)-\(suffix)"; suffix += 1 }
        return candidate
    }

    private func add() {
        var profile = readEditor()
        profile[keyPath: nameKey] = uniqueName(profile[keyPath: nameKey])
        profiles.append(profile)
        index = profiles.count - 1
        refresh()
        writeEditor(profile)
        panel.setStatus("Added “\(profile[keyPath: nameKey])”.", ok: true)
    }

    @discardableResult
    private func modify() -> Bool {
        guard profiles.indices.contains(index) else { return false }
        let profile = readEditor()
        let name = profile[keyPath: nameKey]
        if name.isEmpty {
            NSSound.beep()
            panel.setStatus("Profile name cannot be empty.", ok: false)
            return false
        }
        if profiles.enumerated().contains(where: { $0.offset != index && $0.element[keyPath: nameKey] == name }) {
            NSSound.beep()
            panel.setStatus("Another profile is already named “\(name)”.", ok: false)
            return false
        }
        let oldName = profiles[index][keyPath: nameKey]
        profiles[index] = profile
        if activeName == oldName { activeName = name }
        refresh()
        panel.setStatus("Updated “\(name)”.", ok: true)
        return true
    }

    private func delete() {
        guard profiles.count > 1, profiles.indices.contains(index) else {
            NSSound.beep()
            panel.setStatus("Keep at least one \(kind) profile.", ok: false)
            return
        }
        let removed = profiles.remove(at: index)[keyPath: nameKey]
        if activeName == removed { activeName = profiles[0][keyPath: nameKey] }
        index = max(0, index - 1)
        refresh()
        writeEditor(profiles[index])
        panel.setStatus("Deleted “\(removed)”.", ok: nil)
    }

    private func setActive() {
        guard selectedProfile != nil else { return }
        if isEditorDirty, !modify() { return }
        guard let current = selectedProfile else { return }
        activeName = current[keyPath: nameKey]
        refresh()
        panel.setStatus("Active \(kind) profile: “\(activeName)”.", ok: true)
    }
}
