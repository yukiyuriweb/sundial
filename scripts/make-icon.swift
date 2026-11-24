// Draws the 1024x1024 app icon. Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // macOS icon grid: an 824-point rounded square on a 1024 canvas
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Late-afternoon sky
    NSGradient(colors: [
        NSColor(red: 0.99, green: 0.80, blue: 0.45, alpha: 1),
        NSColor(red: 0.93, green: 0.50, blue: 0.27, alpha: 1),
    ])!.draw(in: shape, angle: -90)

    // The sun, low in the afternoon sky
    let sun = NSBezierPath(ovalIn: NSRect(x: 650, y: 680, width: 150, height: 150))
    NSColor(red: 1, green: 0.96, blue: 0.80, alpha: 0.9).setFill()
    sun.fill()

    // The dial plate, seen at an angle
    let center = NSPoint(x: 500, y: 380)
    let rx: CGFloat = 330, ry: CGFloat = 160
    let ink = NSColor(red: 0.42, green: 0.24, blue: 0.14, alpha: 1)
    let edge = NSBezierPath(ovalIn: NSRect(x: center.x - rx, y: center.y - ry - 34, width: rx * 2, height: ry * 2))
    NSColor(red: 0.78, green: 0.55, blue: 0.38, alpha: 1).setFill()
    edge.fill()
    let plate = NSBezierPath(ovalIn: NSRect(x: center.x - rx, y: center.y - ry, width: rx * 2, height: ry * 2))
    NSColor(red: 1, green: 0.97, blue: 0.90, alpha: 1).setFill()
    plate.fill()

    // Hour marks around the rim
    ink.withAlphaComponent(0.5).setStroke()
    for hour in 0..<24 {
        let angle = CGFloat(hour) / 24 * 2 * .pi
        let major = hour % 3 == 0
        let inner: CGFloat = major ? 0.78 : 0.86, outer: CGFloat = 0.94
        let mark = NSBezierPath()
        mark.move(to: NSPoint(x: center.x + cos(angle) * rx * inner, y: center.y + sin(angle) * ry * inner))
        mark.line(to: NSPoint(x: center.x + cos(angle) * rx * outer, y: center.y + sin(angle) * ry * outer))
        mark.lineWidth = major ? 14 : 8
        mark.lineCapStyle = .round
        mark.stroke()
    }

    // The gnomon's shadow, cast away from the sun
    let shadowPath = NSBezierPath()
    shadowPath.move(to: NSPoint(x: center.x - 150, y: center.y + 40))
    shadowPath.line(to: NSPoint(x: center.x - 230, y: center.y - 70))
    shadowPath.line(to: NSPoint(x: center.x + 40, y: center.y - 6))
    shadowPath.close()
    ink.withAlphaComponent(0.3).setFill()
    shadowPath.fill()

    // The gnomon: an upright triangle along the dial's noon line
    let gnomon = NSBezierPath()
    gnomon.move(to: NSPoint(x: center.x - 150, y: center.y + 40))
    gnomon.line(to: NSPoint(x: center.x - 150, y: center.y + 300))
    gnomon.line(to: NSPoint(x: center.x + 60, y: center.y - 10))
    gnomon.close()
    ink.setFill()
    gnomon.fill()
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
