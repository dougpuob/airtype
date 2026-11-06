import AppKit
import ApplicationServices
import Foundation

/// Geometry-only helpers for placing the floating pill near the text insertion point.
/// Never reads field values / selected text content — only AX ranges/markers and bounds.
///
/// Mature model (external companion, not an IME):
/// - Cooperating text clients expose insertion geometry to the input system via
///   `NSTextInputClient.firstRect(forCharacterRange:actualRange:)` in **screen** coords
///   (zero-width rect for a collapsed caret). AirType cannot call that on another process.
/// - The Accessibility equivalent is `AXSelectedTextRange` + `AXBoundsForRange`
///   (same contract: collapsed range → insertion rect). Convert AX top-left / y-down
///   (relative to the primary display whose Cocoa origin is (0,0)) to AppKit bottom-left
///   with a deterministic primary-height flip — not a containment heuristic.
/// - Reject garbage / whole-field / zero-height “carets”; never center on a wide control
///   and label it caret success.
enum InsertionPointLocator {
    struct Anchor {
        enum Source: String {
            case caretBounds
            case focusedElement
            case focusedWindow
            case savedRatio
        }

        /// Narrow insertion geometry when source == caretBounds; otherwise a
        /// honestly-labeled approximation (never pretends to be a caret).
        let rect: NSRect
        let source: Source
        let detail: String

        var point: NSPoint { NSPoint(x: rect.midX, y: rect.midY) }
    }

    // MARK: - Pure geometry (testable)

    /// AX/Quartz global: top-left origin, Y down from the top of the primary display.
    /// Cocoa screen: bottom-left origin. Flip using the primary (origin == .zero) height.
    static func axToCocoa(_ axRect: CGRect, primaryHeight: CGFloat) -> NSRect {
        NSRect(
            x: axRect.origin.x,
            y: primaryHeight - axRect.origin.y - axRect.size.height,
            width: axRect.size.width,
            height: axRect.size.height
        )
    }

    /// True caret/insertion rect in AX space: finite, non-zero area or zero-width
    /// with positive line height; not CGRect.zero; height must be real (Apple’s
    /// insertion rect has width 0 but positive height). Oversized widths are not carets.
    static func isTrustworthyCaretAX(
        _ axRect: CGRect,
        fieldFrame: CGRect?,
        maxCaretWidth: CGFloat = 40
    ) -> Bool {
        guard axRect.origin.x.isFinite, axRect.origin.y.isFinite,
              axRect.size.width.isFinite, axRect.size.height.isFinite else { return false }
        guard axRect.width >= 0, axRect.height >= 0 else { return false }
        if axRect == .zero { return false }
        // Degenerate Electron/native false success: (0,0,1,0) etc.
        if axRect.height < 4 { return false }
        if axRect.height > 200 { return false }
        if axRect.width > maxCaretWidth { return false }
        if let field = fieldFrame, field.width > 1, field.height > 1 {
            let center = CGPoint(x: axRect.midX, y: axRect.midY)
            // Same AX space as field frame from kAXPosition/kAXSize.
            if !field.insetBy(dx: -24, dy: -24).contains(center) { return false }
        }
        return true
    }

    /// Reject whole-control / whole-window rectangles as insertion anchors.
    static func isOversizedAsCaret(_ axRect: CGRect, fieldFrame: CGRect?) -> Bool {
        if axRect.width > 40 { return true }
        if let field = fieldFrame, field.width > 40, axRect.width > field.width * 0.5 {
            return true
        }
        return false
    }

    static func screenContaining(_ rect: NSRect, screens: [NSRect], margin: CGFloat = 2) -> Int? {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        for (i, frame) in screens.enumerated() where frame.insetBy(dx: -margin, dy: -margin).contains(center) {
            return i
        }
        for (i, frame) in screens.enumerated() where frame.intersects(rect.insetBy(dx: -margin, dy: -margin)) {
            return i
        }
        return nil
    }

    /// Prefer above the caret; if that leaves the caret’s visible frame, place below.
    /// Horizontal: align to caret midX for a narrow caret; for wide fallback rects
    /// the caller should pass a leading-edge hairline so we do not “center the screen”.
    static func panelOrigin(
        forCaretRect caret: NSRect,
        panelSize: NSSize,
        visibleFrame: NSRect,
        gap: CGFloat = 10
    ) -> NSPoint {
        let centeredX = caret.midX - panelSize.width / 2
        let above = NSPoint(x: centeredX, y: caret.maxY + gap)
        let below = NSPoint(x: centeredX, y: caret.minY - panelSize.height - gap)
        let aboveFits = above.y + panelSize.height <= visibleFrame.maxY + 0.5
        let chosen = aboveFits ? above : below
        return NSPoint(
            x: min(max(chosen.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - panelSize.width)),
            y: min(max(chosen.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - panelSize.height))
        )
    }

    /// When empty-range bounds fail, derive a hairline from the previous/next glyph
    /// (same idea as mature caret probes: empty rect at caret → adjacent character).
    static func hairlineFromAdjacentGlyph(
        emptyRangeLocation: Int,
        previousGlyph: CGRect?,
        nextGlyph: CGRect?
    ) -> CGRect? {
        if emptyRangeLocation > 0,
           let prev = previousGlyph,
           prev.height >= 4, prev.width >= 0, prev != .zero {
            return CGRect(x: prev.maxX, y: prev.minY, width: 0, height: prev.height)
        }
        if let next = nextGlyph,
           next.height >= 4, next.width >= 0, next != .zero {
            return CGRect(x: next.minX, y: next.minY, width: 0, height: next.height)
        }
        return nil
    }

    // MARK: - Live AX resolve

    static func resolve(targetPID: pid_t?, savedRatioFallback: () -> NSPoint) -> Anchor {
        let screens = NSScreen.screens
        let screenFrames = screens.map(\.frame)
        let primary = screens.first(where: { $0.frame.origin == .zero }) ?? screens.first
        let primaryHeight = primary?.frame.height ?? 0

        func screenName(_ idx: Int?) -> String {
            guard let idx, screens.indices.contains(idx) else { return "none" }
            return screens[idx].localizedName
        }

        guard AXIsProcessTrusted(), let targetPID, targetPID > 0 else {
            let fallback = savedRatioFallback()
            return Anchor(
                rect: NSRect(x: fallback.x, y: fallback.y, width: 1, height: 1),
                source: .savedRatio,
                detail: "ax_untrusted_or_no_pid"
            )
        }

        let app = AXUIElementCreateApplication(targetPID)

        if let (cocoa, detail) = caretCocoaRect(
            in: app,
            primaryHeight: primaryHeight,
            screenFrames: screenFrames,
            screenName: screenName
        ) {
            return Anchor(rect: cocoa, source: .caretBounds, detail: detail)
        }

        if let (cocoa, detail) = focusedElementLeadingHairline(
            in: app,
            primaryHeight: primaryHeight,
            screenFrames: screenFrames,
            screenName: screenName
        ) {
            return Anchor(rect: cocoa, source: .focusedElement, detail: detail)
        }

        if let (cocoa, detail) = focusedWindowLeadingHairline(
            in: app,
            primaryHeight: primaryHeight,
            screenFrames: screenFrames,
            screenName: screenName
        ) {
            return Anchor(rect: cocoa, source: .focusedWindow, detail: detail)
        }

        let fallback = savedRatioFallback()
        return Anchor(
            rect: NSRect(x: fallback.x, y: fallback.y, width: 1, height: 1),
            source: .savedRatio,
            detail: "no_usable_ax_geometry"
        )
    }

    // MARK: - AX (geometry only)

    private static func caretCocoaRect(
        in app: AXUIElement,
        primaryHeight: CGFloat,
        screenFrames: [NSRect],
        screenName: (Int?) -> String
    ) -> (NSRect, String)? {
        guard let focused = copyElement(app, kAXFocusedUIElementAttribute) else { return nil }
        if isSecureField(focused) { return nil }

        let role = copyString(focused, kAXRoleAttribute) ?? "?"
        let field = axFrame(of: focused)

        // 1) Selected text range → bounds (AppKit / many native apps).
        if let rangeValue = copyValue(focused, kAXSelectedTextRangeAttribute) {
            var cf = CFRange()
            let hasRange = AXValueGetValue(rangeValue as! AXValue, .cfRange, &cf)
            let loc = hasRange ? Int(cf.location) : -1
            let len = hasRange ? Int(cf.length) : -1

            var ax: CGRect?
            var via = "selectedTextRange"

            if let direct = parameterizedBounds(focused, parameter: rangeValue) {
                if isTrustworthyCaretAX(direct, fieldFrame: field), !isOversizedAsCaret(direct, fieldFrame: field) {
                    ax = narrowCaret(direct)
                } else if hasRange, len == 0 {
                    // Empty insertion range returned garbage / zero-height — try adjacent glyphs.
                    let prev: CGRect? = loc > 0
                        ? boundsForCFRange(focused, location: loc - 1, length: 1)
                        : nil
                    let next = boundsForCFRange(focused, location: max(0, loc), length: 1)
                    if let hair = hairlineFromAdjacentGlyph(
                        emptyRangeLocation: loc,
                        previousGlyph: prev,
                        nextGlyph: next
                    ), isTrustworthyCaretAX(hair, fieldFrame: field) {
                        ax = hair
                        via = "adjacentGlyph"
                    }
                }
            } else if hasRange, len == 0 {
                let prev: CGRect? = loc > 0
                    ? boundsForCFRange(focused, location: loc - 1, length: 1)
                    : nil
                let next = boundsForCFRange(focused, location: max(0, loc), length: 1)
                if let hair = hairlineFromAdjacentGlyph(
                    emptyRangeLocation: loc,
                    previousGlyph: prev,
                    nextGlyph: next
                ), isTrustworthyCaretAX(hair, fieldFrame: field) {
                    ax = hair
                    via = "adjacentGlyph"
                }
            }

            if let ax {
                let cocoa = axToCocoa(ax, primaryHeight: primaryHeight)
                guard screenContaining(cocoa, screens: screenFrames) != nil else {
                    return nil
                }
                let idx = screenContaining(cocoa, screens: screenFrames)
                let detail = "role=\(role) via=\(via) loc=\(loc) len=\(len) "
                    + "ax=(\(fmt(ax))) cocoa=(\(fmt(cocoa))) flip=primary "
                    + "screen=\(screenName(idx))"
                return (cocoa, detail)
            }
        }

        // 2) Chromium/Electron: selected text marker range → bounds (public AX attrs).
        if let markerRange = copyValue(focused, "AXSelectedTextMarkerRange"),
           let axRaw = parameterizedBounds(
            focused,
            attribute: "AXBoundsForTextMarkerRange",
            parameter: markerRange
           ) {
            // Marker may span a run; only accept collapsed-caret-like geometry.
            if isTrustworthyCaretAX(axRaw, fieldFrame: field, maxCaretWidth: 4),
               !isOversizedAsCaret(axRaw, fieldFrame: field) {
                let ax = narrowCaret(axRaw)
                let cocoa = axToCocoa(ax, primaryHeight: primaryHeight)
                if screenContaining(cocoa, screens: screenFrames) != nil {
                    let idx = screenContaining(cocoa, screens: screenFrames)
                    let detail = "role=\(role) via=selectedTextMarkerRange "
                        + "ax=(\(fmt(ax))) cocoa=(\(fmt(cocoa))) flip=primary "
                        + "screen=\(screenName(idx))"
                    return (cocoa, detail)
                }
            }
        }

        return nil
    }

    /// Honest fallback: hairline at the leading/top of the focused editable control —
    /// NOT the horizontal mid-line of the whole field (that looked like “screen center”).
    private static func focusedElementLeadingHairline(
        in app: AXUIElement,
        primaryHeight: CGFloat,
        screenFrames: [NSRect],
        screenName: (Int?) -> String
    ) -> (NSRect, String)? {
        guard let focused = copyElement(app, kAXFocusedUIElementAttribute) else { return nil }
        guard let axField = axFrame(of: focused),
              axField.width > 8, axField.height > 4,
              axFrameIsPlausible(axField) else { return nil }

        let role = copyString(focused, kAXRoleAttribute) ?? "?"
        // Leading inset + first-line band (AX top-left): y near field top, height ~ line.
        let lineH = min(22, max(12, axField.height * 0.35))
        let axHair = CGRect(
            x: axField.minX + 6,
            y: axField.minY + 2,
            width: 0,
            height: lineH
        )
        let cocoa = axToCocoa(axHair, primaryHeight: primaryHeight)
        guard screenContaining(cocoa, screens: screenFrames) != nil else { return nil }
        let idx = screenContaining(cocoa, screens: screenFrames)
        let detail = "role=\(role) via=focusedElementLeadingEdge "
            + "field_ax=(\(fmt(axField))) hair_ax=(\(fmt(axHair))) cocoa=(\(fmt(cocoa))) "
            + "flip=primary screen=\(screenName(idx)) limitation=no_trustworthy_caret"
        return (cocoa, detail)
    }

    private static func focusedWindowLeadingHairline(
        in app: AXUIElement,
        primaryHeight: CGFloat,
        screenFrames: [NSRect],
        screenName: (Int?) -> String
    ) -> (NSRect, String)? {
        let window: AXUIElement?
        if let focused = copyElement(app, kAXFocusedUIElementAttribute) {
            window = copyElement(focused, kAXWindowAttribute) ?? copyElement(app, kAXFocusedWindowAttribute)
        } else {
            window = copyElement(app, kAXFocusedWindowAttribute)
        }
        guard let window, let axField = axFrame(of: window),
              axField.width > 40, axField.height > 40,
              axFrameIsPlausible(axField) else { return nil }

        let axHair = CGRect(x: axField.minX + 24, y: axField.minY + 64, width: 0, height: 16)
        let cocoa = axToCocoa(axHair, primaryHeight: primaryHeight)
        guard screenContaining(cocoa, screens: screenFrames) != nil else { return nil }
        let idx = screenContaining(cocoa, screens: screenFrames)
        let detail = "via=focusedWindowLeadingEdge "
            + "window_ax=(\(fmt(axField))) hair_ax=(\(fmt(axHair))) cocoa=(\(fmt(cocoa))) "
            + "flip=primary screen=\(screenName(idx)) limitation=no_trustworthy_caret"
        return (cocoa, detail)
    }

    private static func narrowCaret(_ ax: CGRect) -> CGRect {
        CGRect(x: ax.minX, y: ax.minY, width: min(ax.width, 2), height: ax.height)
    }

    private static func axFrameIsPlausible(_ r: CGRect) -> Bool {
        r.origin.x.isFinite && r.origin.y.isFinite
            && r.size.width.isFinite && r.size.height.isFinite
            && r.width > 0 && r.height > 0
            && r != .zero
    }

    private static func boundsForCFRange(_ element: AXUIElement, location: Int, length: Int) -> CGRect? {
        var range = CFRange(location: location, length: length)
        guard let param = AXValueCreate(.cfRange, &range) else { return nil }
        return parameterizedBounds(element, parameter: param)
    }

    private static func parameterizedBounds(
        _ element: AXUIElement,
        attribute: String = kAXBoundsForRangeParameterizedAttribute as String,
        parameter: CFTypeRef
    ) -> CGRect? {
        var boundsRef: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            attribute as CFString,
            parameter,
            &boundsRef
        )
        guard status == .success, let boundsRef else { return nil }
        return cgRect(from: boundsRef)
    }

    private static func axFrame(of element: AXUIElement) -> CGRect? {
        guard let posRef = copyValue(element, kAXPositionAttribute),
              let sizeRef = copyValue(element, kAXSizeAttribute),
              let origin = cgPoint(from: posRef),
              let size = cgSize(from: sizeRef) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func isSecureField(_ element: AXUIElement) -> Bool {
        (copyString(element, kAXRoleAttribute) ?? "") == "AXSecureTextField"
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref else { return nil }
        return (ref as! AXUIElement)
    }

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
            return nil
        }
        return ref
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        copyValue(element, attribute) as? String
    }

    private static func cgRect(from ref: CFTypeRef) -> CGRect? {
        var rect = CGRect.zero
        guard AXValueGetValue(ref as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private static func cgPoint(from ref: CFTypeRef) -> CGPoint? {
        var point = CGPoint.zero
        guard AXValueGetValue(ref as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func cgSize(from ref: CFTypeRef) -> CGSize? {
        var size = CGSize.zero
        guard AXValueGetValue(ref as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func fmt(_ r: CGRect) -> String {
        String(format: "%.1f,%.1f %.1fx%.1f", r.origin.x, r.origin.y, r.size.width, r.size.height)
    }
}
