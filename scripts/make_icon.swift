import AppKit

// 生成输入法图标:
//   Data/icon.tiff   — 输入菜单用,16pt(1x+2x),过大 会把菜单选项行高撑成两倍
//   Data/appicon.tiff — 安装器 UI/应用图标用,64pt(1x+2x)
func render(size: CGFloat, scale: CGFloat) -> NSBitmapImageRep {
    let px = Int(size * scale)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)

    let rect = NSRect(x: 0.5, y: 0.5, width: size - 1, height: size - 1)
    let radius = size * 0.22
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    NSColor(calibratedRed: 0.15, green: 0.45, blue: 0.95, alpha: 1).setFill()
    rect.fill()
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: size * 0.58),
        .foregroundColor: NSColor.white,
    ]
    let s = NSAttributedString(string: "拼", attributes: attrs)
    let bounds = s.boundingRect(
        with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading])
    s.draw(at: NSPoint(
        x: (size - bounds.width) / 2 - bounds.minX,
        y: (size - bounds.height) / 2 - bounds.minY))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writeIcon(path: String, pointSize: CGFloat) {
    let img = NSImage(size: NSSize(width: pointSize, height: pointSize))
    for scale in [CGFloat(1), CGFloat(2)] {
        img.addRepresentation(render(size: pointSize, scale: scale))
    }
    try! img.tiffRepresentation!.write(to: URL(fileURLWithPath: path))
}

writeIcon(path: "Data/icon.tiff", pointSize: 16)
writeIcon(path: "Data/appicon.tiff", pointSize: 64)
print("icons written: icon.tiff(16pt) appicon.tiff(64pt)")
