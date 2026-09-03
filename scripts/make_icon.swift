import AppKit

// 生成输入法菜单图标 Data/icon.tiff
let size = NSSize(width: 64, height: 64)
let img = NSImage(size: size)
img.lockFocus()
let rect = NSRect(x: 2, y: 2, width: 60, height: 60)
NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).addClip()
NSColor(calibratedRed: 0.15, green: 0.45, blue: 0.95, alpha: 1).setFill()
rect.fill()
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.boldSystemFont(ofSize: 38),
    .foregroundColor: NSColor.white,
]
NSAttributedString(string: "拼", attributes: attrs).draw(at: NSPoint(x: 11, y: 11))
img.unlockFocus()
try! img.tiffRepresentation!.write(to: URL(fileURLWithPath: "Data/icon.tiff"))
print("icon written")
