import AppKit
import Carbon.HIToolbox
import Foundation

/// Pure gesture state for Right Ctrl / Option / Command (synthetic-time testable).
struct HotkeyGestureTracker {
    enum Mode: String {
        case single
        case double
    }

    var mode: Mode
    var doubleThreshold: TimeInterval = 0.4
    var dedupeWindow: TimeInterval = 0.08
    var emitCooldown: TimeInterval = 0.5

    init(mode: Mode) {
        self.mode = mode
    }

    private var lastPhysicalDownAt: [HotkeyKey: TimeInterval] = [:]
    private var lastPhysicalUpAt: [HotkeyKey: TimeInterval] = [:]
    private var lastDownAt: [HotkeyKey: TimeInterval] = [:]
    private var armedExclusiveDown: Set<HotkeyKey> = []
    private var lastEmit: TimeInterval = 0

    mutating func resetTransientState() {
        lastPhysicalDownAt.removeAll()
        lastPhysicalUpAt.removeAll()
        lastDownAt.removeAll()
        armedExclusiveDown.removeAll()
        // Keep lastEmit so a mode switch mid-flight does not double-fire immediately.
    }

    /// Returns true when a start/stop toggle gesture should fire.
    mutating func handle(
        key: HotkeyKey,
        isDown: Bool,
        hasExtraModifiers: Bool,
        now: TimeInterval
    ) -> Bool {
        if isDown {
            if let last = lastPhysicalDownAt[key], now - last < dedupeWindow {
                return false
            }
            lastPhysicalDownAt[key] = now
        } else {
            if let last = lastPhysicalUpAt[key], now - last < dedupeWindow {
                return false
            }
            lastPhysicalUpAt[key] = now
        }

        if isDown {
            if hasExtraModifiers {
                armedExclusiveDown.remove(key)
                lastDownAt[key] = 0
                return false
            }
            armedExclusiveDown.insert(key)
            guard mode == .double else { return false }
            return registerDoubleDown(key, now: now)
        }

        // Key-up / modifier release.
        let wasArmed = armedExclusiveDown.remove(key) != nil
        guard mode == .single else { return false }
        // Combo: another modifier still held, or never armed as exclusive.
        guard wasArmed, !hasExtraModifiers else { return false }
        return emitIfCooled(now: now)
    }

    private mutating func registerDoubleDown(_ key: HotkeyKey, now: TimeInterval) -> Bool {
        let last = lastDownAt[key] ?? 0
        if last > 0, now - last < doubleThreshold {
            lastDownAt[key] = 0
            return emitIfCooled(now: now)
        }
        lastDownAt[key] = now
        return false
    }

    private mutating func emitIfCooled(now: TimeInterval) -> Bool {
        guard now - lastEmit > emitCooldown else { return false }
        lastEmit = now
        return true
    }
}

final class HotkeyMonitor {
    private let onGesture: () -> Void
    private let onEscape: () -> Void
    private let stateLock = NSLock()
    private var eventTap: CFMachPort?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var callback: CGEventTapCallBack?
    private var tracker: HotkeyGestureTracker
    private var triggers: Set<HotkeyKey>
    private var escapeHotKeyRef: EventHotKeyRef?
    private var escapeHandlerRef: EventHandlerRef?
    private var escapeArmed = false
    private var lastEscapeEmit: TimeInterval = 0

    init(
        pressCount: HotkeyGestureTracker.Mode,
        triggers: Set<HotkeyKey> = Set(HotkeyKey.allCases),
        onGesture: @escaping () -> Void,
        onEscape: @escaping () -> Void
    ) {
        self.tracker = HotkeyGestureTracker(mode: pressCount)
        self.triggers = triggers.isEmpty ? Set(HotkeyKey.allCases) : triggers
        self.onGesture = onGesture
        self.onEscape = onEscape
    }

    func setPressCount(_ mode: HotkeyGestureTracker.Mode) {
        stateLock.lock()
        tracker.mode = mode
        tracker.resetTransientState()
        stateLock.unlock()
        Logger.shared.log("Hotkey press count mode=\(mode.rawValue)")
    }

    func setTriggers(_ triggers: Set<HotkeyKey>) {
        let next = triggers.isEmpty ? Set(HotkeyKey.allCases) : triggers
        stateLock.lock()
        self.triggers = next
        tracker.resetTransientState()
        stateLock.unlock()
        let names = next.map(\.rawValue).sorted().joined(separator: ",")
        Logger.shared.log("Hotkey triggers=\(names)")
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
        Logger.shared.log("Hotkey press count mode=\(tracker.mode.rawValue)")
    }

    func stop() {
        disarmEscapeCancel()
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
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
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
            guard let self else { return }
            // Global: other apps focused. Local: AirType focused. Quartz covers both when Input Monitoring is granted.
            if self.globalMonitor == nil {
                self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
                    self?.handleNSEvent(event, source: "nsevent-global")
                }
                Logger.shared.log("NSEvent global flagsChanged monitor started")
            }
            if self.localMonitor == nil {
                self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
                    self?.handleNSEvent(event, source: "nsevent-local")
                    return event
                }
                Logger.shared.log("NSEvent local flagsChanged monitor started")
            }
        }
    }

    private func handleNSEvent(_ event: NSEvent, source: String) {
        if event.type == .keyDown, event.keyCode == 53 {
            handleEscapePress(source: source)
            return
        }
        guard event.type == .flagsChanged else { return }
        let keycode = Int64(event.keyCode)
        let flags = event.modifierFlags
        guard let (key, isDown) = HotkeyKey.nseventEdge(for: keycode, flags: flags) else {
            // Discover remapped Command / Fn / Caps without spamming Shift.
            let flagsInterest = flags.intersection(.deviceIndependentFlagsMask)
            if flagsInterest.contains(.command) || keycode == 57 || keycode == 63 {
                Logger.shared.log(
                    "\(source) unmapped flagsChanged keycode=\(keycode) flags=\(flags.rawValue)"
                )
            }
            return
        }
        guard isTrigger(key) else {
            let names = triggerNamesLocked()
            Logger.shared.log(
                "\(source) ignored keycode=\(keycode) key=\(key.rawValue) flags=\(flags.rawValue) active_triggers=\(names)"
            )
            return
        }
        handleEdge(
            key,
            isDown: isDown,
            hasExtra: HotkeyKey.nseventHasExtraModifiers(flags, besides: key),
            source: source
        )
    }

    private func triggerNamesLocked() -> String {
        stateLock.lock()
        let names = triggers.map(\.rawValue).sorted().joined(separator: ",")
        stateLock.unlock()
        return names
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
        Logger.shared.log("Quartz hotkey listener started: Right Ctrl / Option / Command")
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

        guard let (key, isDown) = HotkeyKey.quartzEdge(for: keycode, flags: flags) else {
            if flags.contains(.maskCommand) || keycode == 57 || keycode == 63 {
                Logger.shared.log(
                    "quartz unmapped flagsChanged keycode=\(keycode) flags=\(flags.rawValue)"
                )
            }
            return
        }
        guard isTrigger(key) else {
            let names = triggerNamesLocked()
            Logger.shared.log(
                "quartz ignored keycode=\(keycode) key=\(key.rawValue) flags=\(flags.rawValue) active_triggers=\(names)"
            )
            return
        }
        handleEdge(
            key,
            isDown: isDown,
            hasExtra: HotkeyKey.quartzHasExtraModifiers(flags, besides: key),
            source: "quartz"
        )
    }

    private func handleEdge(_ key: HotkeyKey, isDown: Bool, hasExtra: Bool, source: String) {
        let now = Date().timeIntervalSinceReferenceDate
        Logger.shared.log(
            "\(key.displayName) \(isDown ? "down" : "up") detected by \(source)"
            + (hasExtra ? " (combo)" : "")
        )

        var shouldEmit = false
        stateLock.lock()
        shouldEmit = tracker.handle(key: key, isDown: isDown, hasExtraModifiers: hasExtra, now: now)
        let mode = tracker.mode
        stateLock.unlock()

        if shouldEmit {
            DispatchQueue.main.async { [onGesture] in
                onGesture()
            }
            Logger.shared.log("\(key.displayName) \(mode.rawValue)-press gesture emitted by \(source)")
        }
    }

    private func handleEscapePress(source: String) {
        let now = Date().timeIntervalSinceReferenceDate
        // Dedupe Carbon + quartz/nsevent if both ever fire.
        stateLock.lock()
        if now - lastEscapeEmit < 0.35 {
            stateLock.unlock()
            Logger.shared.log("Escape press ignored duplicate source=\(source)")
            return
        }
        lastEscapeEmit = now
        let armed = escapeArmed
        stateLock.unlock()
        Logger.shared.log("Escape press detected by \(source) escape_armed=\(armed)")
        DispatchQueue.main.async { [onEscape] in
            onEscape()
        }
    }

    /// Session-scoped Carbon Escape hotkey. Works without Input Monitoring (unlike global keyDown monitors).
    /// Only armed while prepare/recording so idle Escape reaches the frontmost app.
    func armEscapeCancel() {
        DispatchQueue.main.async { [weak self] in
            self?.armEscapeCancelOnMain()
        }
    }

    func disarmEscapeCancel() {
        if Thread.isMainThread {
            disarmEscapeCancelOnMain()
        } else {
            DispatchQueue.main.sync { [weak self] in
                self?.disarmEscapeCancelOnMain()
            }
        }
    }

    private func armEscapeCancelOnMain() {
        stateLock.lock()
        let already = escapeArmed
        stateLock.unlock()
        if already {
            Logger.shared.log("Escape Carbon hotkey already armed")
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature == HotkeyMonitor.escapeHotKeySignature,
                      hotKeyID.id == HotkeyMonitor.escapeHotKeyID else {
                    return OSStatus(eventNotHandledErr)
                }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                monitor.handleEscapePress(source: "carbon")
                // Consume Escape while armed so the focused editor does not also handle it.
                return noErr
            },
            1,
            &eventType,
            userData,
            &handlerRef
        )
        guard installStatus == noErr else {
            Logger.shared.log("Escape Carbon handler install failed status=\(installStatus)")
            return
        }

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(
            signature: Self.escapeHotKeySignature,
            id: Self.escapeHotKeyID
        )
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            Logger.shared.log("Escape Carbon RegisterEventHotKey failed status=\(registerStatus)")
            return
        }

        stateLock.lock()
        escapeHandlerRef = handlerRef
        escapeHotKeyRef = hotKeyRef
        escapeArmed = true
        stateLock.unlock()
        Logger.shared.log("Escape Carbon hotkey armed for active capture session")
    }

    private func disarmEscapeCancelOnMain() {
        stateLock.lock()
        let hotKeyRef = escapeHotKeyRef
        let handlerRef = escapeHandlerRef
        escapeHotKeyRef = nil
        escapeHandlerRef = nil
        let wasArmed = escapeArmed
        escapeArmed = false
        stateLock.unlock()

        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
        if wasArmed {
            Logger.shared.log("Escape Carbon hotkey disarmed")
        }
    }

    private static let escapeHotKeySignature: OSType = 0x4154_4553 // 'ATES'
    private static let escapeHotKeyID: UInt32 = 1

    private func isTrigger(_ hotkeyKey: HotkeyKey) -> Bool {
        stateLock.lock()
        let enabled = triggers.contains(hotkeyKey)
        stateLock.unlock()
        return enabled
    }
}

enum HotkeyKey: String, CaseIterable, Hashable {
    case rightControl = "right_ctrl"
    case rightOption = "right_option"
    case rightCommand = "right_command"

    /// Both sides: 54/55 ⌘, 58/61 ⌥/Alt, 59/62 ⌃. PC keyboards often only send the left keycode.
    static let monitoredKeycodes: Set<Int64> = [54, 55, 58, 59, 61, 62]

    /// Map config `hotkey_trigger` to physical keys.
    /// On macOS, Right Option and Right Alt are the same key (keycode 61).
    static func triggers(fromConfig value: String) -> Set<HotkeyKey> {
        switch value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "right_ctrl", "right-ctrl", "rightcontrol", "right_control", "ctrl":
            return [.rightControl]
        case "right_option", "right-option", "rightoption", "option",
             "right_alt", "right-alt", "rightalt", "alt":
            return [.rightOption]
        case "right_command", "right-command", "rightcommand", "right_cmd", "right-cmd",
             "command", "cmd", "win", "windows":
            return [.rightCommand]
        default:
            // "auto", legacy "both", and unknowns → all right-side triggers.
            return Set(HotkeyKey.allCases)
        }
    }

    var displayName: String {
        switch self {
        case .rightControl: return "Right Ctrl"
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        }
    }

    static func nseventEdge(for keycode: Int64, flags: NSEvent.ModifierFlags) -> (HotkeyKey, Bool)? {
        switch keycode {
        case 59, 62: // Left / Right Control
            return (.rightControl, flags.contains(.control))
        case 58, 61: // Left / Right Option (Right Alt / AltGr)
            return (.rightOption, flags.contains(.option))
        case 54, 55: // Right / Left Command (PC Windows key → usually Left ⌘)
            return (.rightCommand, flags.contains(.command))
        default:
            return nil
        }
    }

    static func quartzEdge(for keycode: Int64, flags: CGEventFlags) -> (HotkeyKey, Bool)? {
        switch keycode {
        case 59, 62: // Left / Right Control
            return (.rightControl, flags.contains(.maskControl))
        case 58, 61: // Left / Right Option (Right Alt / AltGr)
            return (.rightOption, flags.contains(.maskAlternate))
        case 54, 55: // Right / Left Command (PC Windows key → usually Left ⌘)
            return (.rightCommand, flags.contains(.maskCommand))
        default:
            return nil
        }
    }

    static func nseventHasExtraModifiers(_ flags: NSEvent.ModifierFlags, besides key: HotkeyKey) -> Bool {
        let device = flags.intersection(.deviceIndependentFlagsMask)
        let cmd = device.contains(.command)
        let shift = device.contains(.shift)
        let ctrl = device.contains(.control)
        let opt = device.contains(.option)
        switch key {
        case .rightControl: return cmd || shift || opt
        // PC Right Alt (AltGr) often arrives as Option+Control together — still count as Option.
        case .rightOption: return cmd || shift
        case .rightCommand: return shift || ctrl || opt
        }
    }

    static func quartzHasExtraModifiers(_ flags: CGEventFlags, besides key: HotkeyKey) -> Bool {
        let cmd = flags.contains(.maskCommand)
        let shift = flags.contains(.maskShift)
        let ctrl = flags.contains(.maskControl)
        let opt = flags.contains(.maskAlternate)
        switch key {
        case .rightControl: return cmd || shift || opt
        // PC Right Alt (AltGr) often arrives as Option+Control together — still count as Option.
        case .rightOption: return cmd || shift
        case .rightCommand: return shift || ctrl || opt
        }
    }
}
