// Renders the Plantty app icon: a `>_` prompt whose cursor sprouts a leaf.
// usage: swift scripts/make-icon.swift <out.png>   (1024×1024, macOS icon grid)
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt body centered on a 1024 canvas, ~185pt corner radius.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

// Drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
color(0x1E1E2E).setFill()
shape.fill()
ctx.restoreGState()

// Body gradient (Catppuccin Mocha base → crust).
ctx.saveGState()
shape.addClip()
NSGradient(colors: [color(0x313244), color(0x1E1E2E), color(0x11111B)],
           atLocations: [0, 0.45, 1], colorSpace: .sRGB)!.draw(in: body, angle: -90)
// Soft green glow behind the sprout.
NSGradient(colors: [color(0xA6E3A1, 0.22), color(0xA6E3A1, 0)])!
    .draw(fromCenter: NSPoint(x: 640, y: 560), radius: 0, toCenter: NSPoint(x: 640, y: 560), radius: 340, options: [])
ctx.restoreGState()

// Inner top highlight rim.
ctx.saveGState()
shape.addClip()
let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
rim.lineWidth = 4
color(0xFFFFFF, 0.10).setStroke()
rim.stroke()
ctx.restoreGState()

let ink = color(0xCDD6F4)

// `>` chevron.
let chevron = NSBezierPath()
chevron.move(to: NSPoint(x: 270, y: 640))
chevron.line(to: NSPoint(x: 410, y: 512))
chevron.line(to: NSPoint(x: 270, y: 384))
chevron.lineWidth = 64
chevron.lineCapStyle = .round
chevron.lineJoinStyle = .round
ink.setStroke()
chevron.stroke()

// `_` cursor, which doubles as the soil line.
let cursor = NSBezierPath()
cursor.move(to: NSPoint(x: 500, y: 372))
cursor.line(to: NSPoint(x: 760, y: 372))
cursor.lineWidth = 64
cursor.lineCapStyle = .round
color(0xA6E3A1).setStroke()
cursor.stroke()

// Stem growing out of the cursor.
let stem = NSBezierPath()
stem.move(to: NSPoint(x: 630, y: 404))
stem.curve(to: NSPoint(x: 640, y: 600), controlPoint1: NSPoint(x: 630, y: 480), controlPoint2: NSPoint(x: 646, y: 540))
stem.lineWidth = 30
stem.lineCapStyle = .round
color(0x94E2D5).setStroke()
stem.stroke()

func leaf(base: NSPoint, tip: NSPoint, bulge: CGFloat, colors: [NSColor]) {
    let dx = tip.x - base.x, dy = tip.y - base.y
    let len = hypot(dx, dy)
    let nx = -dy / len * bulge, ny = dx / len * bulge
    let path = NSBezierPath()
    path.move(to: base)
    path.curve(to: tip, controlPoint1: NSPoint(x: base.x + dx * 0.25 + nx, y: base.y + dy * 0.25 + ny),
               controlPoint2: NSPoint(x: base.x + dx * 0.8 + nx * 0.6, y: base.y + dy * 0.8 + ny * 0.6))
    path.curve(to: base, controlPoint1: NSPoint(x: base.x + dx * 0.8 - nx * 0.6, y: base.y + dy * 0.8 - ny * 0.6),
               controlPoint2: NSPoint(x: base.x + dx * 0.25 - nx, y: base.y + dy * 0.25 - ny))
    NSGradient(colors: colors)!.draw(in: path, angle: atan2(dy, dx) * 180 / .pi)
    // Midrib.
    let rib = NSBezierPath()
    rib.move(to: base)
    rib.line(to: NSPoint(x: base.x + dx * 0.78, y: base.y + dy * 0.78))
    rib.lineWidth = 7
    rib.lineCapStyle = .round
    color(0x1E1E2E, 0.35).setStroke()
    rib.stroke()
}

leaf(base: NSPoint(x: 640, y: 596), tip: NSPoint(x: 820, y: 740), bulge: 70,
     colors: [color(0x94E2D5), color(0xA6E3A1)])
leaf(base: NSPoint(x: 636, y: 560), tip: NSPoint(x: 480, y: 676), bulge: 58,
     colors: [color(0x74C7EC), color(0xA6E3A1)])

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
