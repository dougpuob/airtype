import AppKit
import Foundation

/// Settings ▸ Endpoints profile list: a table of named profiles with
/// Add / Modify / Delete. The panel only renders and forwards actions;
/// `ProfileSession` owns the data. A profile name is just a label — there is no
/// separate “active” / Set Active concept in the UI.
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

    private var names: [String] = []
    private(set) var selectedIndex = 0
    private var suppress = false
    private let table = NSTableView()
    private let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))

    override init() {
        let container = NSStackView()
        view = container
        super.init()

        nameColumn.title = "Profile"
        nameColumn.width = 320
        table.addTableColumn(nameColumn)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.rowHeight = 20
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 4
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor(calibratedWhite: 0.52, alpha: 1).cgColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // Align roughly with the 480 control column used by endpoint forms.
        scroll.widthAnchor.constraint(equalToConstant: 372).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 112).isActive = true

        func button(_ title: String, _ action: Selector, _ tip: String) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .regular
            b.toolTip = tip
            b.widthAnchor.constraint(equalToConstant: 100).isActive = true
            return b
        }
        let buttons = NSStackView(views: [
            button("Add", #selector(addClicked), "Save the form below as a new profile."),
            button("Modify", #selector(modifyClicked), "Save the form below into the selected profile."),
            button("Delete", #selector(deleteClicked), "Remove the selected profile.")
        ])
        buttons.orientation = .vertical
        buttons.alignment = .leading
        buttons.spacing = 4

        let top = NSStackView(views: [scroll, buttons])
        top.orientation = .horizontal
        top.alignment = .top
        top.spacing = 8

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.preferredMaxLayoutWidth = 480

        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4
        container.addArrangedSubview(top)
        container.addArrangedSubview(statusLabel)
    }

    func reload(names: [String], selected: Int) {
        self.names = names
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
        let id = NSUserInterfaceItemIdentifier("ProfileCell-name")
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
        cell.textField?.stringValue = names[row]
        cell.textField?.font = .systemFont(ofSize: NSFont.systemFontSize)
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
}

/// Data + editor glue for one kind of endpoint profile (Remote ASR, Whisper, LLM).
/// Model: the list holds saved profiles; the form below edits a copy of the selected one.
/// Add = form → new profile, Modify = form → selected profile, Delete = remove selected.
/// Apply / Save folds the selected profile into config as the one the app uses
/// (`default-*-name`). Nothing is written to config.json until Apply / Save.
@MainActor
final class ProfileSession<Profile: Equatable> {
    let kind: String
    let panel = ProfileListPanel()
    private(set) var profiles: [Profile] = []
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
    }

    var selectedProfile: Profile? { profiles.indices.contains(index) ? profiles[index] : nil }

    /// `selecting` keeps a row selected (e.g. after Apply); nil prefers `preferredName`, else first.
    func load(_ list: [Profile], preferredName: String = "", selecting: Int? = nil) {
        profiles = list
        if let selecting, !list.isEmpty {
            index = min(max(0, selecting), list.count - 1)
        } else {
            index = max(0, list.firstIndex(where: { $0[keyPath: nameKey] == preferredName }) ?? 0)
        }
        refresh()
        if let selectedProfile { writeEditor(selectedProfile) }
        panel.setStatus("")
    }

    /// Saved profiles with pending form edits folded into the selected one.
    /// `selected` is the profile currently highlighted — Apply / Save treats it as the one in use.
    func committed() -> (profiles: [Profile], selected: Profile?, selectedName: String) {
        var list = profiles
        if list.indices.contains(index) {
            var edited = readEditor()
            let oldName = list[index][keyPath: nameKey]
            let newName = edited[keyPath: nameKey]
            if newName.isEmpty || list.enumerated().contains(where: { $0.offset != index && $0.element[keyPath: nameKey] == newName }) {
                edited[keyPath: nameKey] = oldName
            }
            list[index] = edited
        }
        let selected = list.indices.contains(index) ? list[index] : list.first
        return (list, selected, selected?[keyPath: nameKey] ?? "")
    }

    var isEditorDirty: Bool {
        guard let selectedProfile else { return false }
        return readEditor() != selectedProfile
    }

    private func refresh() {
        panel.reload(names: profiles.map { $0[keyPath: nameKey] }, selected: index)
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
        profiles[index] = profile
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
        index = max(0, index - 1)
        refresh()
        writeEditor(profiles[index])
        panel.setStatus("Deleted “\(removed)”.", ok: nil)
    }
}
