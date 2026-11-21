import AppKit
import Foundation

/// Shared filter + list + detail chrome for Voice / Obsidian history Settings panes.
@MainActor
final class HistorySettingsPaneController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    enum Kind { case voice, obsidian }

    private let kind: Kind
    private let dateFromPicker = NSDatePicker()
    private let dateToPicker = NSDatePicker()
    private let contentField = NSTextField()
    private let table = NSTableView()
    private let detail = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    let audioDirectoryField = NSTextField()
    private var summaryValues: [NSTextField] = []
    private var voiceRows: [VoiceHistoryRecord] = []
    private var obsidianRows: [ObsidianImportRecord] = []
    private var offset = 0
    private let pageSize = HistoryStore.pageSize
    private var useDateFilter = false
    private let summaryFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    init(kind: Kind) {
        self.kind = kind
        super.init()
    }

    func makeView() -> NSView {
        dateFromPicker.datePickerStyle = .textFieldAndStepper
        dateFromPicker.datePickerElements = [.yearMonthDay]
        dateFromPicker.dateValue = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        dateToPicker.datePickerStyle = .textFieldAndStepper
        dateToPicker.datePickerElements = [.yearMonthDay]
        dateToPicker.dateValue = Date()

        contentField.placeholderString = "Search content…"
        contentField.font = NSFont.systemFont(ofSize: 13)
        contentField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let apply = NSButton(title: "Apply", target: self, action: #selector(applyFilters))
        apply.bezelStyle = .rounded
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearFilters))
        clear.bezelStyle = .rounded
        let more = NSButton(title: "Load More", target: self, action: #selector(loadMore))
        more.bezelStyle = .rounded

        let filterRow = NSStackView(views: [
            label("From"), dateFromPicker,
            label("To"), dateToPicker,
            contentField, apply, clear, more
        ])
        filterRow.orientation = .horizontal
        filterRow.spacing = 8
        filterRow.alignment = .centerY

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        table.style = .plain
        table.headerView = NSTableHeaderView()
        table.rowHeight = 22
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(selectionChanged)
        let colDate = NSTableColumn(identifier: .init("date"))
        colDate.title = "Date"
        colDate.width = 160
        let colSummary = NSTableColumn(identifier: .init("summary"))
        colSummary.title = kind == .voice ? "ASR / LLM" : "Import"
        colSummary.width = 420
        table.addTableColumn(colDate)
        table.addTableColumn(colSummary)

        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder

        detail.isEditable = false
        detail.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        detail.textContainerInset = NSSize(width: 8, height: 8)
        let detailScroll = NSScrollView()
        detailScroll.documentView = detail
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .bezelBorder

        let summaryBlock = makeSummaryBlock()
        var arranged: [NSView] = []
        if kind == .voice {
            arranged.append(makeAudioDirectoryBlock())
        }
        arranged.append(contentsOf: [summaryBlock, filterRow, statusLabel, tableScroll, detailScroll])

        let stack = NSStackView(views: arranged)
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = HistoryDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = document
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            summaryBlock.widthAnchor.constraint(equalTo: stack.widthAnchor),
            filterRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tableScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailScroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        if kind == .voice, let audioBlock = arranged.first {
            audioBlock.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        tableScroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        detailScroll.heightAnchor.constraint(equalToConstant: 180).isActive = true

        reload(reset: true)
        return scroll
    }

    /// Reloads the list and the summary. Called when the History page is shown.
    func refresh() {
        reload(reset: true)
    }

    private func makeAudioDirectoryBlock() -> NSView {
        audioDirectoryField.placeholderString = "Folder for Opus recordings"
        audioDirectoryField.font = .systemFont(ofSize: 13)
        audioDirectoryField.lineBreakMode = .byTruncatingMiddle
        audioDirectoryField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        audioDirectoryField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        let browse = NSButton(title: "Browse…", target: self, action: #selector(browseAudioDirectory))
        browse.bezelStyle = .rounded
        browse.setContentCompressionResistancePriority(.required, for: .horizontal)
        let pathRow = NSStackView(views: [audioDirectoryField, browse])
        pathRow.orientation = .horizontal
        pathRow.alignment = .centerY
        pathRow.spacing = 8

        let note = NSTextField(wrappingLabelWithString:
            "Each voice input is saved here as Opus. The name is the date, time, and the first 10 characters. Leave empty to skip. Click Save to keep this folder."
        )
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 560
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let heading = NSTextField(labelWithString: "Audio Files")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let block = NSStackView(views: [heading, pathRow, note])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 6
        note.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        return block
    }

    private func makeSummaryBlock() -> NSView {
        let titles = ["Today", "This week", "This month", "3 months", "6 months", "1 year", "Total"]
        summaryValues = []
        var columns: [NSView] = []
        for title in titles {
            let caption = NSTextField(labelWithString: title)
            caption.font = .systemFont(ofSize: 11)
            caption.textColor = .secondaryLabelColor
            caption.alignment = .center
            let number = NSTextField(labelWithString: "0")
            number.font = .systemFont(ofSize: 18, weight: .semibold)
            number.alignment = .center
            let column = NSStackView(views: [number, caption])
            column.orientation = .vertical
            column.alignment = .centerX
            column.spacing = 1
            columns.append(column)
            summaryValues.append(number)
        }
        let row = NSStackView(views: columns)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 4
        let heading = NSTextField(labelWithString: "Summary")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let block = NSStackView(views: [heading, row])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 6
        row.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        return block
    }

    @objc private func browseAudioDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder where AirType saves voice-input Opus files"
        let current = (audioDirectoryField.stringValue as NSString).expandingTildeInPath
        if !current.isEmpty, FileManager.default.fileExists(atPath: current) {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if let editor = self.audioDirectoryField.currentEditor() {
                editor.string = url.path
            }
            self.audioDirectoryField.stringValue = url.path
            self.audioDirectoryField.window?.makeFirstResponder(nil)
        }
        if let window = audioDirectoryField.window {
            panel.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(panel.runModal())
        }
    }

    private func refreshSummary() {
        let summary = kind == .voice ? HistoryStore.shared.voiceSummary() : HistoryStore.shared.obsidianSummary()
        let counts = [
            summary.today, summary.thisWeek, summary.thisMonth,
            summary.threeMonths, summary.sixMonths, summary.oneYear, summary.total
        ]
        for (field, count) in zip(summaryValues, counts) {
            field.stringValue = summaryFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
        }
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: 12)
        return field
    }

    private func currentQuery(limit: Int, offset: Int) -> HistoryQuery {
        HistoryQuery(
            dateFrom: useDateFilter ? dateFromPicker.dateValue : nil,
            dateTo: useDateFilter ? dateToPicker.dateValue : nil,
            content: contentField.stringValue,
            limit: limit,
            offset: offset
        )
    }

    @objc private func applyFilters() {
        useDateFilter = true
        reload(reset: true)
    }

    @objc private func clearFilters() {
        useDateFilter = false
        contentField.stringValue = ""
        reload(reset: true)
    }

    @objc private func loadMore() {
        reload(reset: false)
    }

    private func reload(reset: Bool) {
        if reset { offset = 0 }
        let query = currentQuery(limit: pageSize, offset: offset)
        switch kind {
        case .voice:
            let page = HistoryStore.shared.queryVoice(query)
            if reset { voiceRows = page } else { voiceRows.append(contentsOf: page) }
            offset = voiceRows.count
            statusLabel.stringValue = "Showing \(voiceRows.count) voice record(s)"
        case .obsidian:
            let page = HistoryStore.shared.queryObsidianImports(query)
            if reset { obsidianRows = page } else { obsidianRows.append(contentsOf: page) }
            offset = obsidianRows.count
            statusLabel.stringValue = "Showing \(obsidianRows.count) import batch(es)"
        }
        refreshSummary()
        table.reloadData()
        detail.string = ""
    }

    @objc private func selectionChanged() {
        let row = table.selectedRow
        guard row >= 0 else { return }
        switch kind {
        case .voice:
            guard row < voiceRows.count else { return }
            let item = voiceRows[row]
            var lines = [
                "Date: \(item.createdAt)",
                "Result: \(item.result)",
                "ASR: \(item.asrBackend) / \(item.asrEngine) / \(item.asrModel)",
            ]
            if let endpoint = item.asrEndpoint, !endpoint.isEmpty { lines.append("ASR endpoint: \(endpoint)") }
            if item.llmEnabled {
                lines.append("LLM: \(item.llmModel ?? "?") @ \(item.llmEndpoint ?? "?")")
            }
            if let ms = item.durationMs { lines.append("Duration: \(ms) ms") }
            if let path = item.audioPath, !path.isEmpty { lines.append("Audio: \(path)") }
            lines.append("")
            lines.append("— ASR —")
            lines.append(item.asrText)
            if let llm = item.llmText, !llm.isEmpty {
                lines.append("")
                lines.append("— LLM —")
                lines.append(llm)
            }
            detail.string = lines.joined(separator: "\n")
        case .obsidian:
            guard row < obsidianRows.count else { return }
            let item = obsidianRows[row]
            var lines = [
                "Date: \(item.createdAt)",
                "Source: \(item.sourceKind) \(item.sourceURL)",
                "Saved \(item.savedCount), failed \(item.failedCount), skipped \(item.skippedCount)",
                ""
            ]
            for note in item.items {
                lines.append("• [\(note.status)] \(note.title)")
                lines.append("  \(note.markdownPath)")
                if let error = note.error, !error.isEmpty { lines.append("  error: \(error)") }
            }
            detail.string = lines.joined(separator: "\n")
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        kind == .voice ? voiceRows.count : obsidianRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        let text: String
        switch kind {
        case .voice:
            guard row < voiceRows.count else { return nil }
            let item = voiceRows[row]
            if id == "date" {
                text = ISO8601DateFormatter().string(from: item.createdAt)
            } else {
                let preview = item.llmText?.isEmpty == false ? item.llmText! : item.asrText
                text = String(preview.prefix(120)).replacingOccurrences(of: "\n", with: " ")
            }
        case .obsidian:
            guard row < obsidianRows.count else { return nil }
            let item = obsidianRows[row]
            if id == "date" {
                text = ISO8601DateFormatter().string(from: item.createdAt)
            } else {
                text = "\(item.sourceKind): saved \(item.savedCount), failed \(item.failedCount)"
            }
        }
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        return field
    }
}

/// Top-left origin so the history form starts at the top of its scroll view.
private final class HistoryDocumentView: NSView {
    override var isFlipped: Bool { true }
}
