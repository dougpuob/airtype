import AppKit
import Foundation

final class HotkeyMonitor {
    private let onDoublePress: () -> Void
    private let onEscape: () -> Void
    private let stateLock = NSLock()
    private var eventTap: CFMachPort?
    private var globalMonitor: Any?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var callback: CGEventTapCallBack?
    private var lastPressByKey: [HotkeyKey: TimeInterval] = [:]
    private var lastEmit: TimeInterval = 0
    private let threshold: TimeInterval = 0.4
    private let triggers = Set(HotkeyKey.allCases)

    init(onDoublePress: @escaping () -> Void, onEscape: @escaping () -> Void) {
        self.onDoublePress = onDoublePress
        self.onEscape = onEscape
    }

    func start() {
        Logger.shared.log("Accessibility trusted: \(AXIsProcessTrusted())")
        requestInputMonitoringAccess()
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

    private func requestInputMonitoringAccess() {
        let trusted = CGPreflightListenEventAccess()
        Logger.shared.log("Input monitoring trusted: \(trusted)")
        if !trusted {
            let granted = CGRequestListenEventAccess()
            Logger.shared.log("Input monitoring requested: \(granted)")
        }
    }

    private func startGlobalMonitor() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.globalMonitor == nil else { return }
            self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
                guard let self else { return }
                if event.type == .keyDown, event.keyCode == 53 {
                    self.handleEscapePress(source: "nsevent")
                    return
                }

                let keycode = Int64(event.keyCode)
                let flags = event.modifierFlags
                if let hotkeyKey = HotkeyKey.nseventKey(for: keycode, flags: flags), self.isTrigger(hotkeyKey) {
                    self.handleHotkeyPress(hotkeyKey, source: "nsevent")
                } else if HotkeyKey.monitoredKeycodes.contains(keycode) {
                    Logger.shared.log("NSEvent modifier flagsChanged keycode=\(keycode) flags=\(flags.rawValue)")
                }
            }
            Logger.shared.log("NSEvent global flagsChanged monitor started")
        }
    }

    private func run() {
        let eventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
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
        Logger.shared.log("Quartz hotkey listener started: Right Ctrl x2 or Right Option x2")
        CFRunLoopRun()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        if type == .keyDown {
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            if keycode == 53 {
                handleEscapePress(source: "quartz")
            }
            return
        }

        guard type == .flagsChanged else { return }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        if let hotkeyKey = HotkeyKey.quartzKey(for: keycode, flags: flags), isTrigger(hotkeyKey) {
            handleHotkeyPress(hotkeyKey, source: "quartz")
        } else if HotkeyKey.monitoredKeycodes.contains(keycode) {
            Logger.shared.log("Modifier flagsChanged keycode=\(keycode) flags=\(flags.rawValue)")
        }
    }

    private func handleHotkeyPress(_ hotkeyKey: HotkeyKey, source: String) {
        let now = Date().timeIntervalSinceReferenceDate
        Logger.shared.log("\(hotkeyKey.displayName) press detected by \(source)")

        var shouldEmit = false
        stateLock.lock()
        let lastPress = lastPressByKey[hotkeyKey] ?? 0
        if now - lastPress < threshold {
            if now - lastEmit > 0.5 {
                lastEmit = now
                shouldEmit = true
            }
            lastPressByKey[hotkeyKey] = 0
        } else {
            lastPressByKey[hotkeyKey] = now
        }
        stateLock.unlock()

        if shouldEmit {
            DispatchQueue.main.async { [onDoublePress] in
                onDoublePress()
            }
            Logger.shared.log("\(hotkeyKey.displayName) double-press emitted by \(source)")
        }
    }

    private func handleEscapePress(source: String) {
        Logger.shared.log("Escape press detected by \(source)")
        DispatchQueue.main.async { [onEscape] in
            onEscape()
        }
    }

    private func isTrigger(_ hotkeyKey: HotkeyKey) -> Bool {
        triggers.contains(hotkeyKey)
    }
}

enum HotkeyKey: String, CaseIterable, Hashable {
    case rightControl = "right_ctrl"
    case rightOption = "right_option"

    static let monitoredKeycodes: Set<Int64> = [58, 59, 61, 62]

    var displayName: String {
        switch self {
        case .rightControl:
            return "Right Ctrl"
        case .rightOption:
            return "Right Option"
        }
    }

    static func nseventKey(for keycode: Int64, flags: NSEvent.ModifierFlags) -> HotkeyKey? {
        if keycode == 62, flags.contains(.control) {
            return .rightControl
        }
        if keycode == 61, flags.contains(.option) {
            return .rightOption
        }
        return nil
    }

    static func quartzKey(for keycode: Int64, flags: CGEventFlags) -> HotkeyKey? {
        if keycode == 62, flags.contains(.maskControl) {
            return .rightControl
        }
        if keycode == 61, flags.contains(.maskAlternate) {
            return .rightOption
        }
        return nil
    }
}
