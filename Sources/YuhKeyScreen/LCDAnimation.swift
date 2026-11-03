import CoreGraphics
import Foundation
import ImageIO

enum ScaleMode: String, CaseIterable, Identifiable {
    case fill, fit
    var id: String { rawValue }
    var label: String { self == .fill ? tr("Fill", "Lấp đầy", "填充") : tr("Fit", "Vừa khung", "适应") }
}

enum ImageLoadError: LocalizedError {
    case unreadable(String)
    var errorDescription: String? {
        switch self {
        case let .unreadable(name):
            return tr("Can't read \(name).", "Không đọc được \(name).", "无法读取 \(name)。")
        }
    }
}

/// Một file người dùng chọn (ảnh tĩnh hoặc GIF), giữ ảnh gốc để dựng lại khi đổi vị trí / chế độ.
struct SourceImage: Identifiable {
    let id = UUID()
    let url: URL
    /// Đã thu nhỏ sẵn: khi lấp đầy khung vẫn còn gấp đôi độ phân giải màn hình, đủ cho xem trước 2x.
    let frames: [CGImage]
    /// Thời gian từng khung (giây), nil nếu là ảnh tĩnh.
    let delays: [TimeInterval]?
    /// Vị trí ảnh trong khung khi ảnh lớn hơn khung, mỗi trục từ -1 (sát trái/trên) đến 1 (sát phải/dưới).
    var offset = CGPoint.zero
    /// Phóng to / thu nhỏ so với vừa lấp đầy khung (1 = 100%). Chỉ áp dụng ở chế độ lấp đầy.
    var zoom: Double = 1
    static let zoomRange = 0.5...4.0

    var name: String { url.lastPathComponent }
    var size: CGSize { CGSize(width: frames[0].width, height: frames[0].height) }

    static func load(_ url: URL) throws -> SourceImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw ImageLoadError.unreadable(url.lastPathComponent)
        }
        let count = min(CGImageSourceGetCount(src), LCDAnimation.maxFrames)
        let headroom = zoomHeadroom(frameCount: count)
        var frames: [CGImage] = []
        var delays: [TimeInterval] = []
        for i in 0..<count {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(downscaled(img, headroom: headroom))
            delays.append(frameDelay(src, index: i))
        }
        guard !frames.isEmpty else { throw ImageLoadError.unreadable(url.lastPathComponent) }
        return SourceImage(url: url, frames: frames, delays: frames.count > 1 ? delays : nil)
    }

    private static func frameDelay(_ src: CGImageSource, index: Int) -> TimeInterval {
        let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        let dicts: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (dictKey, unclamped, clamped) in dicts {
            if let d = props[dictKey] as? [CFString: Any] {
                return (d[unclamped] as? Double) ?? (d[clamped] as? Double) ?? 0
            }
        }
        return 0
    }

    /// Giữ ảnh đủ nét để phóng to tới `zoomRange.upperBound`, nhưng tổng bộ nhớ các khung không quá ~256MB.
    private static func zoomHeadroom(frameCount: Int) -> Double {
        let previewPixels = Double(LCDAnimation.width * 2 * LCDAnimation.height * 2)
        let budget = 64_000_000.0
        return min(zoomRange.upperBound, max(1, (budget / (previewPixels * Double(max(1, frameCount)))).squareRoot()))
    }

    private static func downscaled(_ img: CGImage, headroom: Double) -> CGImage {
        let w = Double(img.width), h = Double(img.height)
        let s = headroom * max(Double(LCDAnimation.width * 2) / w, Double(LCDAnimation.height * 2) / h)
        guard s < 1 else { return img }
        let nw = max(1, Int((w * s).rounded())), nh = max(1, Int((h * s).rounded()))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage() ?? img
    }

    /// Ảnh có lớn hơn khung ở trục nào không (chỉ xảy ra ở chế độ lấp đầy), tức là kéo được.
    func canPan(_ mode: ScaleMode, zoom: Double? = nil) -> Bool {
        let r = LCDAnimation.placement(of: size, mode: mode, offset: .zero, zoom: zoom ?? self.zoom)
        return r.width > CGFloat(LCDAnimation.width) + 0.5 || r.height > CGFloat(LCDAnimation.height) + 0.5
    }
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
    /// Khung thứ i lấy từ ảnh nguồn nào, khung nào (để xem trước vẽ thẳng từ ảnh gốc).
    var origins: [(source: Int, frame: Int)]
    var truncated = false

    var totalDuration: TimeInterval { delays.reduce(0) { $0 + Double($1) / 100 } }

    /// Vị trí ảnh trong khung 160×80, gốc toạ độ ở góc trên bên trái.
    static func placement(of size: CGSize, mode: ScaleMode, offset: CGPoint, zoom: Double) -> CGRect {
        let W = CGFloat(width), H = CGFloat(height)
        let sx = W / size.width, sy = H / size.height
        let s = mode == .fill ? max(sx, sy) * CGFloat(zoom) : min(sx, sy)
        let w = size.width * s, h = size.height * s
        func origin(_ frame: CGFloat, _ len: CGFloat, _ o: CGFloat) -> CGFloat {
            let overflow = len - frame
            return overflow > 0 ? -overflow * (1 + o) / 2 : -overflow / 2
        }
        return CGRect(x: origin(W, w, offset.x), y: origin(H, h, offset.y), width: w, height: h)
    }

    /// Ghép các ảnh nguồn theo thứ tự. Ảnh tĩnh hiện `slideDelay` giây; GIF giữ nhịp gốc.
    static func build(from sources: [SourceImage], mode: ScaleMode, slideDelay: TimeInterval) -> LCDAnimation? {
        var anim = LCDAnimation(frames: [], delays: [], origins: [])
        let single = sources.count == 1
        outer: for (si, src) in sources.enumerated() {
            for (fi, img) in src.frames.enumerated() {
                if anim.frames.count == maxFrames {
                    anim.truncated = true
                    break outer
                }
                anim.frames.append(render(img, rect: placement(of: src.size, mode: mode, offset: src.offset, zoom: src.zoom)))
                let seconds = src.delays?[fi] ?? (single ? 0 : slideDelay)
                anim.delays.append(delayUnits(seconds, isStatic: src.delays == nil && !single))
                anim.origins.append((si, fi))
            }
        }
        return anim.frames.isEmpty ? nil : anim
    }

    /// Driver gốc coi khung GIF ≤ 40ms (và ảnh tĩnh đơn) là 200ms.
    private static func delayUnits(_ seconds: TimeInterval, isStatic: Bool) -> UInt8 {
        let ms = Int((seconds * 1000).rounded())
        if isStatic { return UInt8(min(255, max(1, ms / 10))) }
        if ms <= 40 { return 20 }
        return UInt8(min(255, ms / 10))
    }

    private static func render(_ img: CGImage, rect: CGRect) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        // CoreGraphics tính y từ dưới lên.
        ctx.draw(img, in: CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
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
