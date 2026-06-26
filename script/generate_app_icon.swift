import AppKit

let outputDirectory = CommandLine.arguments.dropFirst().first.map(URL.init(fileURLWithPath:))
    ?? URL(fileURLWithPath: "FloatyApp/FloatyApp/Assets.xcassets/AppIcon.appiconset")

let icons: [(name: String, pixels: Int)] = [
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

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for icon in icons {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: icon.pixels,
        pixelsHigh: icon.pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: icon.pixels, height: icon.pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(icon.pixels))
    NSGraphicsContext.restoreGraphicsState()

    let destination = outputDirectory.appendingPathComponent(icon.name)
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: destination, options: .atomic)
}

private func drawIcon(size: CGFloat) {
    let scale = size / 1024
    let bounds = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    bounds.fill()

    let baseRect = bounds.insetBy(dx: 70 * scale, dy: 70 * scale)
    let basePath = NSBezierPath(roundedRect: baseRect, xRadius: 230 * scale, yRadius: 230 * scale)
    basePath.addClip()

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.82, green: 0.91, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.33, green: 0.55, blue: 0.86, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.28, alpha: 1)
    ])!
    gradient.draw(in: baseRect, angle: -38)

    NSColor(calibratedWhite: 1, alpha: 0.24).setFill()
    NSBezierPath(roundedRect: baseRect.insetBy(dx: 34 * scale, dy: 40 * scale), xRadius: 190 * scale, yRadius: 190 * scale).fill()

    let widgetRect = NSRect(x: 247 * scale, y: 228 * scale, width: 530 * scale, height: 600 * scale)
    let widgetPath = NSBezierPath(roundedRect: widgetRect, xRadius: 98 * scale, yRadius: 98 * scale)
    NSColor(calibratedWhite: 0.98, alpha: 0.78).setFill()
    widgetPath.fill()
    NSColor(calibratedRed: 0.15, green: 0.22, blue: 0.33, alpha: 0.18).setStroke()
    widgetPath.lineWidth = 7 * scale
    widgetPath.stroke()

    drawWave(in: NSRect(x: 314 * scale, y: 301 * scale, width: 180 * scale, height: 70 * scale), scale: scale)
    drawBars(scale: scale)
    drawAgentDots(scale: scale)
    drawSparkline(scale: scale)

    NSColor(calibratedWhite: 1, alpha: 0.26).setFill()
    NSBezierPath(ovalIn: NSRect(x: 180 * scale, y: 720 * scale, width: 220 * scale, height: 110 * scale)).fill()
}

private func drawWave(in rect: NSRect, scale: CGFloat) {
    let path = NSBezierPath()
    path.lineWidth = 22 * scale
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: NSPoint(x: rect.minX, y: rect.midY))
    path.line(to: NSPoint(x: rect.minX + 30 * scale, y: rect.midY))
    path.line(to: NSPoint(x: rect.minX + 55 * scale, y: rect.minY + 10 * scale))
    path.line(to: NSPoint(x: rect.minX + 86 * scale, y: rect.maxY - 8 * scale))
    path.line(to: NSPoint(x: rect.minX + 120 * scale, y: rect.midY))
    path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
    NSColor(calibratedRed: 0.14, green: 0.19, blue: 0.28, alpha: 0.88).setStroke()
    path.stroke()
}

private func drawBars(scale: CGFloat) {
    let heights: [CGFloat] = [98, 148, 204, 120, 248, 166, 88]
    for (index, height) in heights.enumerated() {
        let x = (314 + CGFloat(index) * 52) * scale
        let y = (506 - height) * scale
        let rect = NSRect(x: x, y: y, width: 25 * scale, height: height * scale)
        let path = NSBezierPath(roundedRect: rect, xRadius: 13 * scale, yRadius: 13 * scale)
        (index < 4 ? NSColor(calibratedRed: 0.17, green: 0.77, blue: 0.43, alpha: 1) : NSColor(calibratedRed: 0.70, green: 0.75, blue: 0.82, alpha: 0.9)).setFill()
        path.fill()
    }
}

private func drawAgentDots(scale: CGFloat) {
    let colors = [
        NSColor(calibratedRed: 0.17, green: 0.77, blue: 0.43, alpha: 1),
        NSColor(calibratedRed: 0.17, green: 0.77, blue: 0.43, alpha: 1),
        NSColor(calibratedRed: 0.96, green: 0.58, blue: 0.12, alpha: 1)
    ]
    for index in 0..<3 {
        let y = (596 + CGFloat(index) * 72) * scale
        NSColor(calibratedRed: 0.18, green: 0.22, blue: 0.30, alpha: 0.18).setFill()
        NSBezierPath(roundedRect: NSRect(x: 314 * scale, y: y, width: 280 * scale, height: 24 * scale), xRadius: 12 * scale, yRadius: 12 * scale).fill()
        colors[index].setFill()
        NSBezierPath(ovalIn: NSRect(x: 638 * scale, y: (y - 3 * scale), width: 30 * scale, height: 30 * scale)).fill()
    }
}

private func drawSparkline(scale: CGFloat) {
    let path = NSBezierPath()
    path.lineWidth = 14 * scale
    path.lineCapStyle = .round
    let points: [CGPoint] = [
        CGPoint(x: 433, y: 648), CGPoint(x: 470, y: 632), CGPoint(x: 505, y: 660),
        CGPoint(x: 545, y: 646), CGPoint(x: 582, y: 662), CGPoint(x: 620, y: 642)
    ]
    for (index, point) in points.enumerated() {
        let scaled = NSPoint(x: point.x * scale, y: point.y * scale)
        index == 0 ? path.move(to: scaled) : path.line(to: scaled)
    }
    NSColor(calibratedRed: 0.17, green: 0.77, blue: 0.43, alpha: 1).setStroke()
    path.stroke()
}
