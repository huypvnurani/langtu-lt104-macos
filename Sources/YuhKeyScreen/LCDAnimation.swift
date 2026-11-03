import CoreGraphics
import Foundation
import ImageIO

enum ScaleMode: String, CaseIterable, Identifiable {
    case fill, fit
    var id: String { rawValue }
    var label: String { self == .fill ? tr("Fill", "Lấp đầy", "填充") : tr("Fit", "Vừa khung", "适应") }
}

/// Animation đã chuyển về đúng khổ màn hình LT104: 160×80, tối đa 255 khung.
struct LCDAnimation {
    static let width = 160
    static let height = 80
    static let maxFrames = 255
    static let headerSize = 256

    var frames: [CGImage]
    /// Thời gian mỗi khung, đơn vị 10ms (giống driver gốc).
    var delays: [UInt8]
    var truncated = false

    var totalDuration: TimeInterval { delays.reduce(0) { $0 + Double($1) / 100 } }

    enum LoadError: LocalizedError {
        case unreadable
        var errorDescription: String? { tr("Can't read this image file.", "Không đọc được file ảnh này.", "无法读取该图片文件。") }
    }

    static func load(from url: URL, mode: ScaleMode) throws -> LCDAnimation {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw LoadError.unreadable }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { throw LoadError.unreadable }

        var anim = LCDAnimation(frames: [], delays: [], truncated: count > maxFrames)
        for i in 0..<min(count, maxFrames) {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            anim.frames.append(render(img, mode: mode))
            anim.delays.append(delayUnits(src, index: i))
        }
        guard !anim.frames.isEmpty else { throw LoadError.unreadable }
        return anim
    }

    /// Driver gốc coi khung ≤ 40ms (và ảnh tĩnh) là 200ms.
    private static func delayUnits(_ src: CGImageSource, index: Int) -> UInt8 {
        let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        let dicts: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        var seconds: Double = 0
        for (dictKey, unclamped, clamped) in dicts {
            if let d = props[dictKey] as? [CFString: Any] {
                seconds = (d[unclamped] as? Double) ?? (d[clamped] as? Double) ?? 0
                break
            }
        }
        let ms = Int((seconds * 1000).rounded())
        if ms <= 40 { return 20 }
        return UInt8(min(255, ms / 10))
    }

    private static func render(_ img: CGImage, mode: ScaleMode) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high

        let sx = Double(width) / Double(img.width)
        let sy = Double(height) / Double(img.height)
        let s = mode == .fill ? max(sx, sy) : min(sx, sy)
        let w = Double(img.width) * s
        let h = Double(img.height) * s
        ctx.draw(img, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
        return ctx.makeImage()!
    }

    /// Khối dữ liệu gửi xuống bàn phím:
    /// header 256 byte [số khung, delay từng khung..., 0xFF...], rồi các khung RGB565 little-endian
    /// nối liền nhau, cuối cùng đệm 0xFF cho đủ bội số 4096.
    func encode() -> Data {
        let framePixels = Self.width * Self.height * 2
        let dataLen = Self.headerSize + frames.count * framePixels
        let total = (dataLen + LT104.chunkSize - 1) / LT104.chunkSize * LT104.chunkSize

        var buf = [UInt8](repeating: 0xFF, count: total)
        buf[0] = UInt8(frames.count)
        for (i, d) in delays.enumerated() { buf[1 + i] = d }

        var offset = Self.headerSize
        for frame in frames {
            let ctx = CGContext(data: nil, width: Self.width, height: Self.height, bitsPerComponent: 8,
                                bytesPerRow: Self.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(frame, in: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
            let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
            for i in 0..<(Self.width * Self.height) {
                let r = UInt16(px[i * 4]), g = UInt16(px[i * 4 + 1]), b = UInt16(px[i * 4 + 2])
                let v = (r >> 3) << 11 | (g >> 2) << 5 | (b >> 3)
                buf[offset] = UInt8(v & 0xFF)
                buf[offset + 1] = UInt8(v >> 8)
                offset += 2
            }
        }
        return Data(buf)
    }

    var chunkCount: Int {
        (Self.headerSize + frames.count * Self.width * Self.height * 2 + LT104.chunkSize - 1) / LT104.chunkSize
    }

    /// Ước lượng thời gian nạp: mỗi gói 4096 byte bàn phím ghi flash mất khoảng 150ms.
    var estimatedUploadSeconds: Int { Int((Double(chunkCount) * 0.15).rounded(.up)) }
}
