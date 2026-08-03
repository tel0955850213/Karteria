import AppKit

enum PromoVariant: String, CaseIterable {
    case monthly
    case annual

    var badgeText: String { self == .monthly ? "M" : "Y" }

    var badgeColor: NSColor {
        self == .monthly
            ? NSColor(calibratedRed: 0.18, green: 0.44, blue: 0.88, alpha: 1)
            : NSColor(calibratedRed: 0.97, green: 0.38, blue: 0.31, alpha: 1)
    }
}

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: generate_subscription_promos.swift INPUT OUTPUT_DIRECTORY\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let canvasSize = NSSize(width: 1024, height: 1024)

guard let source = NSImage(contentsOf: inputURL) else {
    fputs("Unable to load source icon.\n", stderr)
    exit(1)
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for variant in PromoVariant.allCases {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 1024,
        pixelsHigh: 1024,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fputs("Unable to create the image canvas.\n", stderr)
        exit(1)
    }

    bitmap.size = canvasSize
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.15, alpha: 1).setFill()
    NSRect(origin: .zero, size: canvasSize).fill()
    source.draw(in: NSRect(origin: .zero, size: canvasSize))

    let badgeRect = NSRect(x: 782, y: 70, width: 148, height: 148)
    variant.badgeColor.setFill()
    NSBezierPath(ovalIn: badgeRect).fill()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 78, weight: .bold),
        .foregroundColor: NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.91, alpha: 1),
        .paragraphStyle: paragraph
    ]
    variant.badgeText.draw(
        in: NSRect(x: badgeRect.minX, y: badgeRect.minY + 27, width: badgeRect.width, height: 96),
        withAttributes: attributes
    )

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) else {
        fputs("Unable to encode \(variant.rawValue) image.\n", stderr)
        exit(1)
    }

    let destination = outputDirectory.appendingPathComponent("pro-\(variant.rawValue).jpg")
    try jpeg.write(to: destination, options: .atomic)
}
