import AppKit
import Foundation

let outputPath = "Karteria/Assets.xcassets/AppIcon.appiconset/Icon-1024.png"
let size = NSSize(width: 1_024, height: 1_024)
let image = NSImage(size: size)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}

image.lockFocus()
color(25, 29, 33).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

func stroke(from start: CGPoint, to end: CGPoint, color: NSColor, width: CGFloat) {
    let path = NSBezierPath()
    path.move(to: start)
    path.line(to: end)
    path.lineWidth = width
    path.lineCapStyle = .round
    color.setStroke()
    path.stroke()
}

let convergence = CGPoint(x: 360, y: 512)
stroke(from: CGPoint(x: 360, y: 224), to: CGPoint(x: 360, y: 800), color: color(247, 242, 232), width: 54)
stroke(from: convergence, to: CGPoint(x: 730, y: 250), color: color(31, 87, 216), width: 58)
stroke(from: convergence, to: CGPoint(x: 730, y: 774), color: color(232, 79, 65), width: 58)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
else {
    fatalError("Could not encode the Karteria app icon.")
}

try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
