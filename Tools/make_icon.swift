import AppKit
let directory = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let bounds = NSRect(x: 72, y: 72, width: 880, height: 880)
let shape = NSBezierPath(roundedRect: bounds, xRadius: 190, yRadius: 190)
NSGradient(
    starting: NSColor(calibratedRed: 0.10, green: 0.24, blue: 0.31, alpha: 1),
    ending: NSColor(calibratedRed: 0.04, green: 0.09, blue: 0.16, alpha: 1))!.draw(in: shape, angle: -60)
NSColor.white.withAlphaComponent(0.08).setStroke()
shape.lineWidth = 4
shape.stroke()
let circle = NSBezierPath(ovalIn: NSRect(x: 245, y: 320, width: 430, height: 430))
circle.lineWidth = 44
NSColor(calibratedRed: 0.45, green: 0.91, blue: 0.86, alpha: 1).setStroke()
circle.stroke()
let handle = NSBezierPath()
handle.move(to: NSPoint(x: 625, y: 355))
handle.line(to: NSPoint(x: 785, y: 195))
handle.lineWidth = 62
handle.lineCapStyle = .round
handle.stroke()
let wave = NSBezierPath()
wave.move(to: NSPoint(x: 300, y: 525))
for p in [
    NSPoint(x: 365, y: 525), NSPoint(x: 400, y: 610), NSPoint(x: 455, y: 440), NSPoint(x: 505, y: 600),
    NSPoint(x: 545, y: 525), NSPoint(x: 620, y: 525)
] { wave.line(to: p) }
wave.lineWidth = 24
wave.lineCapStyle = .round
wave.lineJoinStyle = .round
NSColor.white.setStroke()
wave.stroke()
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(
    to: URL(fileURLWithPath: directory).appendingPathComponent("icon.png"))
