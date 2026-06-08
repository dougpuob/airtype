import AppKit

enum StatusIcon {
    static func make(recording: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 18, height: 18).fill()

        let ink = recording ? NSColor.systemRed : NSColor.labelColor
        ink.setStroke()
        ink.setFill()

        let body = NSBezierPath(roundedRect: NSRect(x: 6, y: 5, width: 6, height: 10), xRadius: 3, yRadius: 3)
        body.fill()

        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: NSPoint(x: 9, y: 8),
            radius: 6,
            startAngle: 205,
            endAngle: 335,
            clockwise: false
        )
        arc.lineWidth = 1.6
        arc.stroke()

        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: 9, y: 2))
        stand.line(to: NSPoint(x: 9, y: 5))
        stand.move(to: NSPoint(x: 6, y: 2))
        stand.line(to: NSPoint(x: 12, y: 2))
        stand.lineWidth = 1.6
        stand.stroke()

        image.unlockFocus()
        image.isTemplate = !recording
        return image
    }
}
