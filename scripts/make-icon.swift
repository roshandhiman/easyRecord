import AppKit

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform()
        transform.scale(by: factor)
        transform.concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 196, yRadius: 196)
        NSColor(white: 0.08, alpha: 1).setFill()
        tile.fill()
        NSColor(white: 0.28, alpha: 1).setStroke()
        tile.lineWidth = 3
        tile.stroke()
        let screen = NSBezierPath(roundedRect: NSRect(x: 230, y: 290, width: 564, height: 418), xRadius: 48, yRadius: 48)
        NSColor(white: 0.7, alpha: 1).setStroke()
        screen.lineWidth = 26
        screen.stroke()
        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: 512, y: 285))
        stand.line(to: NSPoint(x: 512, y: 218))
        stand.move(to: NSPoint(x: 414, y: 218))
        stand.line(to: NSPoint(x: 610, y: 218))
        stand.lineWidth = 26
        stand.lineCapStyle = .round
        stand.stroke()
        NSColor(red: 0.94, green: 0.27, blue: 0.29, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 422, y: 409, width: 180, height: 180)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(destination)/icon_\(size)x\(size)\(suffix).png"))
    }
}
