import AppKit
import Foundation

final class HotkeyMonitor {
    private let onDoublePress: () -> Void
    private var eventTap: CFMachPort?
    private var globalMonitor: Any?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var callback: CGEventTapCallBack?
    private var lastRightControlPress: TimeInterval = 0
    private var lastEmit: TimeInterval = 0
    private let threshold: TimeInterval = 0.4

    init(onDoublePress: @escaping () -> Void) {
        self.onDoublePress = onDoublePress
    }

    func start() {
        Logger.shared.log("Accessibility trusted: \(AXIsProcessTrusted())")
        startGlobalMonitor()
        thread = Thread { [weak self] in
            self?.run()
        }
        thread?.name = "AirTypeHotkeyMonitor"
        thread?.start()
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        eventTap = nil
        runLoop = nil
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func startGlobalMonitor() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.globalMonitor == nil else { return }
            self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self else { return }
                let keycode = Int64(event.keyCode)
                let flags = event.modifierFlags
                if keycode == 62, flags.contains(.control) {
                    self.handleRightControlPress(source: "nsevent")
                } else if keycode == 59 || keycode == 62 {
                    Logger.shared.log("NSEvent control flagsChanged keycode=\(keycode) flags=\(flags.rawValue)")
                }
            }
            Logger.shared.log("NSEvent global flagsChanged monitor started")
        }
    }

    private func run() {
        let eventMask = (1 << CGEventType.flagsChanged.rawValue)
        callback = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let callback else { return }
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap else {
            Logger.shared.log("Could not create Quartz event tap. Check Accessibility permission.")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        Logger.shared.log("Quartz hotkey listener started: Right Ctrl x2")
        CFRunLoopRun()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        guard type == .flagsChanged else { return }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let rightControlKeycode: Int64 = 62

        if keycode == rightControlKeycode, flags.contains(.maskControl) {
            handleRightControlPress(source: "quartz")
        } else if keycode == 59 || keycode == 62 {
            Logger.shared.log("Control flagsChanged keycode=\(keycode) flags=\(flags.rawValue)")
        }
    }

    private func handleRightControlPress(source: String) {
        let now = Date().timeIntervalSinceReferenceDate
        Logger.shared.log("Right Ctrl press detected by \(source)")
        if now - lastRightControlPress < threshold {
            if now - lastEmit > 0.5 {
                lastEmit = now
                DispatchQueue.main.async { [onDoublePress] in
                    onDoublePress()
                }
                Logger.shared.log("Right Ctrl double-press emitted by \(source)")
            }
            lastRightControlPress = 0
        } else {
            lastRightControlPress = now
        }
    }
}
