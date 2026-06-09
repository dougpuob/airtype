#!/usr/bin/env swift

import AppKit
import Foundation

let outputURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AirType.icns")
let fileManager = FileManager.default
let workDir = outputURL.deletingLastPathComponent()
let iconsetURL = workDir.appendingPathComponent("AirType.iconset")

try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in sizes {
    let image = makeIcon(size: size)
    let destination = iconsetURL.appendingPathComponent(name)
    try writePNG(image, to: destination)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()

if process.terminationStatus != 0 {
    throw NSError(
        domain: "AirType.Icon",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: "iconutil failed"]
    )
}

try? fileManager.removeItem(at: iconsetURL)

func makeIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.white.setFill()
    rect.fill()

    let scale = size / 1024 * 1.08
    let offset = (size - 1024 * scale) / 2
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: offset + x * scale, y: offset + y * scale)
    }
    func r(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
        NSRect(x: offset + x * scale, y: offset + y * scale, width: width * scale, height: height * scale)
    }

    NSColor.black.setFill()
    NSColor.black.setStroke()

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

    drawAccentBlob(in: r(84, 671, 205, 126), angle: -18, cutout: r(133, 710, 88, 24))
    drawAccentBlob(in: r(806, 95, 120, 86), angle: -38, cutout: r(844, 120, 54, 17))

    NSColor.white.setFill()
    NSColor.white.setStroke()
    drawLetterA(in: r(328, 205, 368, 430), scale: scale)
    drawMinusBadge(in: r(616, 553, 260, 260), scale: scale)

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let data = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "AirType.Icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not render PNG"])
    }
    try data.write(to: url)
}

func drawLetterA(in rect: NSRect, scale: CGFloat) {
    let lineWidth = max(1, 54 * scale)
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

func drawMinusBadge(in rect: NSRect, scale: CGFloat) {
    let outer = NSBezierPath(ovalIn: rect)
    outer.lineWidth = max(1, 34 * scale)
    outer.stroke()

    let minus = NSBezierPath()
    minus.lineCapStyle = .round
    minus.lineWidth = max(1, 30 * scale)
    minus.move(to: NSPoint(x: rect.minX + 86 * scale, y: rect.midY))
    minus.line(to: NSPoint(x: rect.maxX - 86 * scale, y: rect.midY))
    minus.stroke()
}

func drawAccentBlob(in rect: NSRect, angle: CGFloat, cutout: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: rect.midX, yBy: rect.midY)
    transform.rotate(byDegrees: angle)
    transform.translateX(by: -rect.midX, yBy: -rect.midY)
    transform.concat()

    NSColor.black.setFill()
    NSBezierPath(ovalIn: rect).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: cutout, xRadius: cutout.height / 2, yRadius: cutout.height / 2).fill()
    NSGraphicsContext.restoreGraphicsState()
}
