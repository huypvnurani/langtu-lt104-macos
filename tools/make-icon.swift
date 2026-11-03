// Vẽ icon app (bàn phím có màn hình đồng hồ) ra PNG 1024×1024.
// Dùng: swift tools/make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Nền: khung bo tròn kiểu macOS (lề 100px như template của Apple).
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35).cgColor)
rgb(0x1B2340).setFill()
tilePath.fill()
ctx.restoreGState()
NSGradient(starting: rgb(0x2C3A66), ending: rgb(0x121829))!.draw(in: tilePath, angle: -90)

// Thân bàn phím (dời lên cho cân giữa khung).
ctx.translateBy(x: 0, y: 105)
let body = NSRect(x: 170, y: 250, width: 684, height: 330)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 48, yRadius: 48)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.45).cgColor)
rgb(0xE9ECF4).setFill()
bodyPath.fill()
ctx.restoreGState()
NSGradient(starting: rgb(0xF4F6FB), ending: rgb(0xC9CFDD))!.draw(in: bodyPath, angle: -90)

// Phím: 3 hàng, chừa chỗ góc trên bên phải cho màn hình.
let keyColor = rgb(0x3A4366)
func key(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat = 62) {
    keyColor.setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: 14, yRadius: 14).fill()
}
let left: CGFloat = 205, gap: CGFloat = 14, unit: CGFloat = 62
for i in 0..<4 { key(left + CGFloat(i) * (unit + gap), 480, unit) }              // hàng trên (cạnh màn hình)
for i in 0..<8 { key(left + CGFloat(i) * (unit + gap), 400, unit) }              // hàng giữa
key(left, 320, unit * 1.6)                                                        // hàng dưới
key(left + unit * 1.6 + gap, 320, unit * 4.4 + gap * 3)                           // phím cách
key(left + unit * 6 + gap * 5, 320, unit * 2 + gap)

// Màn hình nhỏ với giờ.
let screen = NSRect(x: 512, y: 474, width: 307, height: 74)
rgb(0x0B0F1C).setFill()
NSBezierPath(roundedRect: screen.insetBy(dx: -8, dy: -8), xRadius: 18, yRadius: 18).fill()
NSGradient(starting: rgb(0x0E2A3A), ending: rgb(0x07131D))!
    .draw(in: NSBezierPath(roundedRect: screen, xRadius: 10, yRadius: 10), angle: -90)

let font = NSFont.monospacedDigitSystemFont(ofSize: 64, weight: .heavy)
let glow = NSShadow()
glow.shadowColor = rgb(0x3EE6FF, 0.9)
glow.shadowBlurRadius = 18
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: rgb(0x7FF3FF), .shadow: glow]
let text = NSAttributedString(string: "10:09", attributes: attrs)
let ts = text.size()
text.draw(at: NSPoint(x: screen.midX - ts.width / 2, y: screen.midY - ts.height / 2 + 2))

// Viền sáng RGB dưới thân bàn phím.
let strip = NSBezierPath(roundedRect: NSRect(x: 210, y: 228, width: 604, height: 14), xRadius: 7, yRadius: 7)
NSGradient(colors: [rgb(0xFF4D8D), rgb(0xFFB443), rgb(0x45E08A), rgb(0x3EC8FF), rgb(0x9B6BFF)])!
    .draw(in: strip, angle: 0)

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
