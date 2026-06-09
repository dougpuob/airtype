import AppKit

enum AirTypeIcon {
    private static let recordingBlue = NSColor(calibratedRed: 0.34, green: 0.74, blue: 1.0, alpha: 1.0)

    static func appIcon(size: CGFloat = 512) -> NSImage {
        make(size: NSSize(width: size, height: size), foreground: .black, background: .white, template: false)
    }

    static func statusIcon(recording: Bool) -> NSImage {
        let image = make(
            size: NSSize(width: 18, height: 18),
            foreground: recording ? recordingBlue : .labelColor,
            background: nil,
            template: !recording
        )
        return image
    }

    private static func make(
        size: NSSize,
        foreground: NSColor,
        background: NSColor?,
        template: Bool
    ) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(origin: .zero, size: size)
        NSColor.clear.setFill()
        rect.fill()
        background?.setFill()
        background.map { _ in rect.fill() }

        let scale = min(size.width, size.height) / 1024 * 1.08
        let xOffset = (size.width - 1024 * scale) / 2
        let yOffset = (size.height - 1024 * scale) / 2

        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: xOffset + x * scale, y: yOffset + y * scale)
        }

        func r(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
            NSRect(x: xOffset + x * scale, y: yOffset + y * scale, width: width * scale, height: height * scale)
        }

        foreground.setFill()
        foreground.setStroke()

        let body = NSBezierPath()
        body.move(to: p(512, 986))
        body.curve(to: p(438, 928), controlPoint1: p(480, 986), controlPoint2: p(459, 963))
        body.curve(to: p(217, 557), controlPoint1: p(355, 789), controlPoint2: p(263, 671))
        body.curve(to: p(167, 326), controlPoint1: p(185, 477), controlPoint2: p(164, 402))
        body.curve(to: p(510, 38), controlPoint1: p(174, 147), controlPoint2: p(318, 38))
        body.curve(to: p(857, 330), controlPoint1: p(707, 38), controlPoint2: p(852, 150))
        body.curve(to: p(808, 554), controlPoint1: p(860, 402), controlPoint2: p(842, 475))
        body.curve(to: p(588, 928), controlPoint1: p(762, 671), controlPoint2: p(673, 789))
        body.curve(to: p(512, 986), controlPoint1: p(566, 963), controlPoint2: p(544, 986))
        body.close()
        body.fill()

        drawAccentBlob(in: r(84, 671, 205, 126), angle: -18, cutout: r(133, 710, 88, 24), scale: scale, color: foreground)
        drawAccentBlob(in: r(806, 95, 120, 86), angle: -38, cutout: r(844, 120, 54, 17), scale: scale, color: foreground)

        cutOrPaint(background: background, scale: scale) {
            drawLetterA(in: r(328, 205, 368, 430), scale: scale)
            drawMinusBadge(in: r(616, 553, 260, 260), scale: scale)
        }

        image.unlockFocus()
        image.isTemplate = template
        return image
    }

    private static func cutOrPaint(background: NSColor?, scale: CGFloat, draw: () -> Void) {
        if let background {
            background.setFill()
            background.setStroke()
            draw()
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .clear
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawLetterA(in rect: NSRect, scale: CGFloat) {
        let lineWidth = 54 * scale
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = lineWidth
        path.move(to: NSPoint(x: rect.minX + 25 * scale, y: rect.minY + 20 * scale))
        path.line(to: NSPoint(x: rect.midX, y: rect.maxY - 20 * scale))
        path.line(to: NSPoint(x: rect.maxX - 25 * scale, y: rect.minY + 20 * scale))
        path.move(to: NSPoint(x: rect.minX + 72 * scale, y: rect.minY + 112 * scale))
        path.line(to: NSPoint(x: rect.maxX - 72 * scale, y: rect.minY + 112 * scale))
        path.stroke()
    }

    private static func drawMinusBadge(in rect: NSRect, scale: CGFloat) {
        let outer = NSBezierPath(ovalIn: rect)
        outer.lineWidth = 34 * scale
        outer.stroke()

        let minus = NSBezierPath()
        minus.lineCapStyle = .round
        minus.lineWidth = 30 * scale
        minus.move(to: NSPoint(x: rect.minX + 86 * scale, y: rect.midY))
        minus.line(to: NSPoint(x: rect.maxX - 86 * scale, y: rect.midY))
        minus.stroke()
    }

    private static func drawAccentBlob(in rect: NSRect, angle: CGFloat, cutout: NSRect, scale: CGFloat, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX, yBy: rect.midY)
        transform.rotate(byDegrees: angle)
        transform.translateX(by: -rect.midX, yBy: -rect.midY)
        transform.concat()

        color.setFill()
        NSBezierPath(ovalIn: rect).fill()

        NSGraphicsContext.current?.compositingOperation = .clear
        let shine = NSBezierPath(roundedRect: cutout, xRadius: cutout.height / 2, yRadius: cutout.height / 2)
        shine.fill()
        NSGraphicsContext.restoreGraphicsState()

        if let context = NSGraphicsContext.current {
            context.compositingOperation = .sourceOver
        }
    }
}
