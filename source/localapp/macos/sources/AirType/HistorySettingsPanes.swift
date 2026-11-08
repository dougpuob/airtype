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
    private var voiceRows: [VoiceHistoryRecord] = []
    private var obsidianRows: [ObsidianImportRecord] = []
    private var offset = 0
    private let pageSize = HistoryStore.pageSize
    private var useDateFilter = false

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
        tableScroll.heightAnchor.constraint(equalToConstant: 220).isActive = true

        detail.isEditable = false
        detail.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        detail.textContainerInset = NSSize(width: 8, height: 8)
        let detailScroll = NSScrollView()
        detailScroll.documentView = detail
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .bezelBorder
        detailScroll.heightAnchor.constraint(equalToConstant: 240).isActive = true

        let stack = NSStackView(views: [filterRow, statusLabel, tableScroll, detailScroll])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let wrap = NSView()
        wrap.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: wrap.topAnchor),
            stack.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            filterRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tableScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailScroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        reload(reset: true)
        return wrap
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
