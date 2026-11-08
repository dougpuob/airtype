import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class FloatingPanelController {
    private let normalSize = NSSize(width: 144, height: 32)
    private let errorSize = NSSize(width: 220, height: 32)
    // localapp: wider panel that shows the streaming (partial) transcript under the timer row.
    private let textSize = NSSize(width: 380, height: 66)
    // Overlay text: up to `FloatingPanelModel.maxTextLines` lines. Past two lines the panel grows
    // upward (its bottom edge stays where the two-line panel ended) so the newest text stays visible.
    private let textFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private let textWidth: CGFloat = 380 - 24
    private var textAnchorTop: CGFloat?
    private let configStore: ConfigStore
    private let onMove: (Double, Double) -> Void
    private let model = FloatingPanelModel()
    private lazy var panel: NSPanel = makePanel()

    init(configStore: ConfigStore, onMove: @escaping (Double, Double) -> Void) {
        self.configStore = configStore
        self.onMove = onMove
    }

    func showPreparing(targetPID: pid_t? = nil) {
        panel.setContentSize(normalSize)
        model.reset()
        model.prepare()
        positionNearInsertionPoint(targetPID: targetPID)
        panel.orderFrontRegardless()
    }

    func showRecording(targetPID: pid_t? = nil) {
        panel.setContentSize(normalSize)
        model.reset()
        if !panel.isVisible {
            positionNearInsertionPoint(targetPID: targetPID)
        }
        panel.orderFrontRegardless()
        model.start()
    }

    func showTranscribing(targetPID: pid_t? = nil) {
        panel.setContentSize(normalSize)
        model.reset()
        model.transcribe()
        if !panel.isVisible {
            positionNearInsertionPoint(targetPID: targetPID)
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        textAnchorTop = nil
        model.stop()
        panel.orderOut(nil)
    }

    /// localapp: show the live transcript; keeps the panel's top edge fixed while resizing.
    func setPartialText(_ text: String) {
        model.partialText = text
        guard !text.isEmpty else {
            textAnchorTop = nil
            resizeKeepingTop(to: normalSize)
            return
        }
        let lines = lineCount(for: FloatingPanelModel.displayText(text))
        let lineHeight = ceil(textFont.ascender - textFont.descender + textFont.leading) + 1
        let extra = CGFloat(max(0, lines - 2)) * lineHeight
        let size = NSSize(width: textSize.width, height: textSize.height + extra)
        if textAnchorTop == nil || panel.frame.size == normalSize {
            textAnchorTop = panel.frame.maxY
        }
        guard let anchorTop = textAnchorTop, panel.frame.size != size else { return }
        // <= 2 lines: top stays put. > 2 lines: bottom stays where the two-line panel ended,
        // so the whole window moves up instead of growing down / off screen.
        let bottom = anchorTop - textSize.height
        var frame = NSRect(x: panel.frame.midX - size.width / 2, y: bottom, width: size.width, height: size.height)
        let visible = screenFrame(containing: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        panel.setFrame(frame, display: true)
    }

    private func lineCount(for text: String) -> Int {
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: textFont]
        )
        let lineHeight = textFont.ascender - textFont.descender + textFont.leading
        let lines = Int(ceil(rect.height / max(1, lineHeight) - 0.05))
        return min(FloatingPanelModel.maxTextLines, max(1, lines))
    }

    /// localapp: recording stopped, flushing the last chunk through Nemotron.
    func showFinalizing() {
        model.finalize()
        panel.orderFrontRegardless()
    }

    private func resizeKeepingTop(to size: NSSize) {
        guard panel.frame.size != size else { return }
        let top = panel.frame.maxY
        let centerX = panel.frame.midX
        let frame = NSRect(x: centerX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }

    func showMicrophoneError(_ message: String) {
        panel.setContentSize(errorSize)
        model.showError(message)
        positionPanel()
        panel.orderFrontRegardless()
    }

    func clearMicrophoneError() {
        guard model.errorText != nil else { return }
        hide()
    }

    func setLevel(_ level: Double) {
        model.setLevel(level)
    }

    func applyConfig() {
        if panel.isVisible {
            positionPanel()
        }
    }

    private func makePanel() -> NSPanel {
        let rootView = FloatingPanelView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        let panel = MovablePanel(
            contentRect: NSRect(origin: .zero, size: normalSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: rootView)
        // Pill is always movable; drag updates saved position ratios used as insertion-point fallback.
        panel.onDrag = { [weak self] frame in
            self?.save(frame: frame)
        }
        panel.canDrag = { true }
        return panel
    }

    private func positionPanel() {
        let desktop = desktopFrame()
        let center = savedRatioCenter()
        let origin = NSPoint(x: center.x - panel.frame.width / 2, y: center.y - panel.frame.height / 2)
        panel.setFrameOrigin(clamped(origin, desktop: desktop))
    }

    /// Place the pill near the text insertion point of the target app.
    /// Never uses the mouse location. Manual/fixed ratio placement remains `positionPanel()`
    /// (mic errors / applyConfig / unlocked drag).
    private func positionNearInsertionPoint(targetPID: pid_t?) {
        // Ensure we have a real size before clamping (setContentSize can lag frame.size).
        if panel.frame.width < 8 || panel.frame.height < 8 {
            panel.setContentSize(normalSize)
        }
        let panelSize = panel.frame.size.width >= 8 ? panel.frame.size : normalSize

        let anchor = InsertionPointLocator.resolve(targetPID: targetPID) { [weak self] in
            guard let self else { return .zero }
            return self.savedRatioCenter()
        }
        let visible = visibleFrame(containingRect: anchor.rect, fallbackPoint: anchor.point)
        let origin: NSPoint
        if anchor.source == .savedRatio {
            origin = NSPoint(
                x: anchor.point.x - panelSize.width / 2,
                y: anchor.point.y - panelSize.height / 2
            )
        } else {
            origin = InsertionPointLocator.panelOrigin(
                forCaretRect: anchor.rect,
                panelSize: panelSize,
                visibleFrame: visible
            )
        }
        let clampedOrigin = clamped(origin, desktop: visible, size: panelSize)
        panel.setFrame(NSRect(origin: clampedOrigin, size: panelSize), display: true)
        let a = anchor.rect
        let v = visible
        let screensDesc = NSScreen.screens.enumerated().map { idx, s in
            let f = s.frame
            return String(format: "[%d:%@ %.0f,%.0f %.0fx%.0f@%.0fx]", idx, s.localizedName as CVarArg, f.origin.x, f.origin.y, f.width, f.height, s.backingScaleFactor)
        }.joined(separator: " ")
        Logger.shared.log(
            "Floating pill positioned: source=\(anchor.source.rawValue), "
            + "target_pid=\(targetPID.map(String.init) ?? "none"), "
            + "ax_trusted=\(AXIsProcessTrusted()), "
            + String(format: "anchor=(%.1f,%.1f %.1fx%.1f), ", a.origin.x, a.origin.y, a.width, a.height)
            + String(format: "visible=(%.1f,%.1f %.1fx%.1f), ", v.origin.x, v.origin.y, v.width, v.height)
            + String(format: "origin=(%.1f,%.1f), ", clampedOrigin.x, clampedOrigin.y)
            + "screens=\(screensDesc), "
            + "detail=\(anchor.detail)"
        )
    }

    private func visibleFrame(containingRect rect: NSRect, fallbackPoint: NSPoint) -> NSRect {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        if let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -2, dy: -2).contains(center) }) {
            return screen.visibleFrame
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect.insetBy(dx: -2, dy: -2)) }) {
            return screen.visibleFrame
        }
        return screenFrame(containing: fallbackPoint)
    }

    private func savedRatioCenter() -> NSPoint {
        let desktop = desktopFrame()
        let x = desktop.minX + desktop.width * configStore.config.floatingDialog.positionXRatio
        let y = desktop.minY + desktop.height * configStore.config.floatingDialog.positionYRatio
        return NSPoint(x: x, y: y)
    }

    private func save(frame: NSRect) {
        let desktop = desktopFrame()
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let xRatio = (center.x - desktop.minX) / max(1, desktop.width)
        let yRatio = (center.y - desktop.minY) / max(1, desktop.height)
        onMove(xRatio, yRatio)
    }

    private func desktopFrame() -> NSRect {
        NSScreen.screens
            .map(\.frame)
            .reduce(NSScreen.main?.frame ?? .zero) { $0.union($1) }
    }

    private func screenFrame(containing point: NSPoint) -> NSRect {
        NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? desktopFrame()
    }

    private func clamped(_ point: NSPoint, desktop: NSRect, size: NSSize? = nil) -> NSPoint {
        let sz = size ?? panel.frame.size
        return NSPoint(
            x: min(max(point.x, desktop.minX), max(desktop.minX, desktop.maxX - sz.width)),
            y: min(max(point.y, desktop.minY), max(desktop.minY, desktop.maxY - sz.height))
        )
    }
}

final class FloatingPanelModel: ObservableObject {
    @Published var elapsedText = "00:00"
    @Published var transcribingDots = ""
    @Published var levels = Array(repeating: 0.08, count: 24)
    @Published var errorText: String?
    @Published var isTranscribing = false
    @Published var partialText = ""

    static let maxTextLines = 5
    /// Tail of the transcript shown in the overlay (head-truncated past `maxTextLines`).
    static func displayText(_ text: String) -> String { String(text.suffix(220)) }

    private var startedAt = Date()
    private var timer: Timer?

    func start() {
        isTranscribing = false
        transcribingDots = ""
        startedAt = Date()
        elapsedText = "00:00"
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func prepare() {
        isTranscribing = false
        transcribingDots = ""
        timer?.invalidate()
        timer = nil
        elapsedText = "..."
        levels = Array(repeating: 0.08, count: 24)
    }

    func transcribe() {
        var dotCount = 0
        isTranscribing = true
        transcribingDots = "..."
        timer?.invalidate()
        elapsedText = "Transcribing"
        levels = Array(repeating: 0.08, count: 24)
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            dotCount = (dotCount % 3) + 1
            self?.transcribingDots = String(repeating: ".", count: dotCount)
        }
    }

    func showError(_ message: String) {
        isTranscribing = false
        transcribingDots = ""
        timer?.invalidate()
        timer = nil
        errorText = message
        levels = Array(repeating: 0.08, count: 24)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        reset()
    }

    func finalize() {
        timer?.invalidate()
        timer = nil
        isTranscribing = true
        transcribingDots = ""
        elapsedText = "Finalizing"
    }

    func reset() {
        partialText = ""
        isTranscribing = false
        transcribingDots = ""
        errorText = nil
        elapsedText = "00:00"
        levels = Array(repeating: 0.08, count: 24)
    }

    func setLevel(_ level: Double) {
        let clipped = min(1.0, max(0.02, level))
        levels = Array(levels.dropFirst()) + [clipped]
    }

    private func tick() {
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        elapsedText = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }
}

struct FloatingPanelView: View {
    @ObservedObject var model: FloatingPanelModel

    var body: some View {
        Group {
            if let errorText = model.errorText {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(errorText)
                        .lineLimit(1)
                }
                .font(.system(size: 12, weight: .bold, design: .default))
                .foregroundStyle(.red)
            } else {
              VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if model.isTranscribing {
                        HStack(spacing: 0) {
                            Text(model.elapsedText)
                            Text(model.transcribingDots)
                                .frame(width: 14, alignment: .leading)
                        }
                        .font(.system(size: 12, weight: .bold, design: .default))
                        .foregroundStyle(.white)
                        .frame(minWidth: 112)
                    } else {
                        Text(model.elapsedText)
                            .font(.system(size: 12, weight: .bold, design: .default))
                            .foregroundStyle(.white)
                            .frame(minWidth: 42)
                    }

                    if !model.isTranscribing {
                        WaveformView(levels: model.levels)
                            .frame(width: 70, height: 18)
                    }
                }
                if !model.partialText.isEmpty {
                    Text(FloatingPanelModel.displayText(model.partialText))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(FloatingPanelModel.maxTextLines)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                }
              }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.09, green: 0.11, blue: 0.13))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    model.errorText == nil
                        ? Color(red: 0.33, green: 0.91, blue: 0.60)
                        : .red,
                    lineWidth: 1
                )
        )
    }
}

struct WaveformView: View {
    let levels: [Double]

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 1) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(red: 0.33, green: 0.91, blue: 0.60).opacity(0.9))
                        .frame(width: 2, height: max(2, geometry.size.height * level))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

final class MovablePanel: NSPanel {
    var onDrag: ((NSRect) -> Void)?
    var canDrag: (() -> Bool)?

    private var dragOffset = NSPoint.zero
    private var dragging = false

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard canDrag?() ?? false else { return }
        dragging = true
        let location = event.locationInWindow
        dragOffset = NSPoint(x: location.x, y: frame.height - location.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let point = NSEvent.mouseLocation
        setFrameOrigin(NSPoint(x: point.x - dragOffset.x, y: point.y - (frame.height - dragOffset.y)))
        onDrag?(frame)
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            dragging = false
            onDrag?(frame)
        }
    }
}
