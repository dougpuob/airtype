import AppKit
import SwiftUI

@MainActor
final class FloatingPanelController {
    private let normalSize = NSSize(width: 144, height: 32)
    private let errorSize = NSSize(width: 220, height: 32)
    private let configStore: ConfigStore
    private let onMove: (Double, Double) -> Void
    private let model = FloatingPanelModel()
    private lazy var panel: NSPanel = makePanel()

    init(configStore: ConfigStore, onMove: @escaping (Double, Double) -> Void) {
        self.configStore = configStore
        self.onMove = onMove
    }

    func showPreparing() {
        panel.setContentSize(normalSize)
        model.reset()
        model.prepare()
        positionPanelBelowCursor()
        panel.orderFrontRegardless()
    }

    func showRecording() {
        panel.setContentSize(normalSize)
        model.reset()
        if !panel.isVisible {
            positionPanelBelowCursor()
        }
        panel.orderFrontRegardless()
        model.start()
    }

    func showTranscribing() {
        panel.setContentSize(normalSize)
        model.reset()
        model.transcribe()
        if !panel.isVisible {
            positionPanelBelowCursor()
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        model.stop()
        panel.orderOut(nil)
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
        panel.onDrag = { [weak self] frame in
            guard let self else { return }
            if self.configStore.config.floatingDialog.moveLock { return }
            self.save(frame: frame)
        }
        panel.canDrag = { [weak self] in
            !(self?.configStore.config.floatingDialog.moveLock ?? true)
        }
        return panel
    }

    private func positionPanel() {
        let desktop = desktopFrame()
        let x = desktop.minX + desktop.width * configStore.config.floatingDialog.positionXRatio
        let y = desktop.minY + desktop.height * configStore.config.floatingDialog.positionYRatio
        let origin = NSPoint(x: x - panel.frame.width / 2, y: y - panel.frame.height / 2)
        panel.setFrameOrigin(clamped(origin, desktop: desktop))
    }

    private func positionPanelBelowCursor() {
        let cursor = NSEvent.mouseLocation
        let screenFrame = screenFrame(containing: cursor)
        let gap: CGFloat = 18
        let origin = NSPoint(
            x: cursor.x - panel.frame.width / 2,
            y: cursor.y - panel.frame.height - gap
        )
        panel.setFrameOrigin(clamped(origin, desktop: screenFrame))
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

    private func clamped(_ point: NSPoint, desktop: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(point.x, desktop.minX), desktop.maxX - panel.frame.width),
            y: min(max(point.y, desktop.minY), desktop.maxY - panel.frame.height)
        )
    }
}

final class FloatingPanelModel: ObservableObject {
    @Published var elapsedText = "00:00"
    @Published var transcribingDots = ""
    @Published var levels = Array(repeating: 0.08, count: 24)
    @Published var errorText: String?
    @Published var isTranscribing = false

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

    func reset() {
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
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Capsule()
                .fill(Color(red: 0.09, green: 0.11, blue: 0.13))
        )
        .overlay(
            Capsule()
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
