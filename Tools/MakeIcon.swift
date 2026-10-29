import AppKit
let folder = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
func render(_ pixels: Int) -> Data {
    // Fixed pixels avoid lockFocus doubling dimensions on Retina displays.
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!
    let scale = CGFloat(pixels) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
    let rect = NSRect(x: 70, y: 70, width: 884, height: 884)
    let path = NSBezierPath(roundedRect: rect, xRadius: 195, yRadius: 195)
    NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
    path.fill()
    let inner = NSBezierPath(roundedRect: NSRect(x: 254, y: 249, width: 410, height: 470), xRadius: 67, yRadius: 67)
    NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
    inner.fill()
    NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 460, y: 490, width: 270, height: 265), xRadius: 30, yRadius: 30).fill()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 428, y: 427)); arrow.line(to: NSPoint(x: 723, y: 722))
    arrow.move(to: NSPoint(x: 553, y: 722)); arrow.line(to: NSPoint(x: 723, y: 722)); arrow.line(to: NSPoint(x: 723, y: 552))
    arrow.lineWidth = 66; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    NSColor(calibratedWhite: 0.96, alpha: 1).setStroke(); arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: URL(fileURLWithPath: folder + "/icon_\(size)x\(size).png"))
    try render(size * 2).write(to: URL(fileURLWithPath: folder + "/icon_\(size)x\(size)@2x.png"))
}
