import Foundation
import IOKit
import IOKit.hid
import IOUSBHost

enum LT104Error: LocalizedError {
    case notConnected
    case lcdNotFound
    case io(String, IOReturn)

    var errorDescription: String? {
        switch self {
        case .notConnected: return tr("LT104 not found. Connect the USB cable (Bluetooth/2.4G can't control the screen).", "Không thấy LT104. Cần cắm dây USB (Bluetooth/2.4G không chỉnh được màn hình).", "未检测到 LT104。请连接 USB 数据线（蓝牙/2.4G 模式无法控制屏幕）。")
        case .lcdNotFound: return tr("Can't open the keyboard's screen interface.", "Không mở được cổng màn hình của bàn phím.", "无法打开键盘的屏幕接口。")
        case let .io(what, code): return "\(what) " + tr("failed", "lỗi", "失败") + " (0x\(String(UInt32(bitPattern: code), radix: 16)))."
        }
    }
}

/// Giao tiếp với LANGTU LT104 (USB 0c45:8009) qua dây USB.
///
/// - Interface 3: lệnh 64 byte qua HID SET_REPORT / GET_REPORT (feature). macOS không gắn driver
///   cho interface này nên gửi thẳng control transfer trên endpoint 0.
/// - Interface 2 (usage page 0xFF68): dữ liệu màn hình, output report 4096 byte,
///   bàn phím trả input report 64 byte sau mỗi gói để báo đã ghi xong.
///
/// Giao thức theo https://github.com/iiaiiappa/lt104-keyboard-linux (giải mã từ DeviceDriver.exe).
/// Không thread-safe: mọi lệnh phải chạy tuần tự trên cùng một queue.
final class LT104 {
    static let vendorID = 0x0C45
    static let productID = 0x8009
    static let lcdUsagePage = 0xFF68
    static let chunkSize = 4096

    private let usb: IOUSBHostDevice

    static func matchingDictionary() -> CFMutableDictionary {
        IOUSBHostDevice.__createMatchingDictionary(
            withVendorID: NSNumber(value: vendorID), productID: NSNumber(value: productID),
            bcdDevice: nil, deviceClass: nil, deviceSubclass: nil, deviceProtocol: nil,
            speed: nil, productIDArray: nil
        ).takeRetainedValue()
    }

    static var isConnected: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matchingDictionary())
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, Self.matchingDictionary())
        guard service != 0 else { throw LT104Error.notConnected }
        defer { IOObjectRelease(service) }
        usb = try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
    }

    deinit { usb.destroy() }

    // MARK: - Interface 3: lệnh điều khiển

    private func setFeature(_ bytes: [UInt8]) throws {
        var pkt = [UInt8](repeating: 0, count: 64)
        pkt.replaceSubrange(0..<min(bytes.count, 64), with: bytes.prefix(64))
        let data = NSMutableData(bytes: &pkt, length: 64)
        let req = IOUSBDeviceRequest(bmRequestType: 0x21, bRequest: 0x09, wValue: 0x0300, wIndex: 3, wLength: 64)
        var sent = 0
        try usb.__send(req, data: data, bytesTransferred: &sent, completionTimeout: 1.5)
    }

    private func getFeature() -> [UInt8]? {
        let data = NSMutableData(length: 64)!
        let req = IOUSBDeviceRequest(bmRequestType: 0xA1, bRequest: 0x01, wValue: 0x0300, wIndex: 3, wLength: 64)
        var got = 0
        guard (try? usb.__send(req, data: data, bytesTransferred: &got, completionTimeout: 1.5)) != nil else { return nil }
        return [UInt8](Data(referencing: data).prefix(got))
    }

    /// Gửi lệnh [b0, b1, ...] rồi chờ bàn phím trả lại đúng [b0, b1]. Hết giờ vẫn đi tiếp như driver gốc.
    private func command(_ b0: UInt8, _ b1: UInt8, extra: [Int: UInt8] = [:]) throws {
        var pkt = [UInt8](repeating: 0, count: 64)
        pkt[0] = b0
        pkt[1] = b1
        for (i, v) in extra { pkt[i] = v }
        try setFeature(pkt)
        for _ in 0..<30 {
            usleep(5_000)
            if let r = getFeature(), r.count >= 2, r[0] == b0, r[1] == b1 { return }
        }
    }

    // MARK: - Đồng hồ

    func syncClock(to date: Date = Date()) throws {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        try command(0x04, 0x18)
        try command(0x04, 0x28, extra: [8: 0x01])

        var pkt = [UInt8](repeating: 0, count: 64)
        pkt[1] = 0x01 // kiểu 24h
        pkt[2] = 0x5A
        pkt[3] = UInt8(c.year! % 100)
        pkt[4] = UInt8(c.month!)
        pkt[5] = UInt8(c.day!)
        pkt[6] = UInt8(c.hour!)
        pkt[7] = UInt8(c.minute!)
        pkt[8] = UInt8(c.second!)
        pkt[62] = 0x55
        pkt[63] = 0xAA
        try setFeature(pkt)
        usleep(20_000)

        try command(0x04, 0x02)
    }

    // MARK: - Màn hình

    /// Ghi animation vào flash (slot 1), bàn phím tự lặp kể cả khi rút cáp.
    /// `payload` là dữ liệu từ `LCDAnimation.encode()`, độ dài là bội số của 4096.
    func uploadAnimation(_ payload: Data, slot: UInt8 = 1, progress: (Double) -> Void) throws {
        precondition(payload.count % Self.chunkSize == 0)
        let lcd = try LCDChannel()
        defer { lcd.close() }

        let chunks = payload.count / Self.chunkSize
        try command(0x04, 0x18)

        var start = [UInt8](repeating: 0, count: 64)
        start[0] = 0x04
        start[1] = 0x72
        start[2] = slot
        start[8] = UInt8(chunks & 0xFF)
        start[9] = UInt8((chunks >> 8) & 0xFF)
        try setFeature(start)
        _ = getFeature()

        for i in 0..<chunks {
            let chunk = payload.subdata(in: i * Self.chunkSize ..< (i + 1) * Self.chunkSize)
            try lcd.write(chunk)
            if lcd.waitForAck(timeout: 0.5) {
                usleep(10_000)
            } else {
                usleep(145_000)
            }
            progress(Double(i + 1) / Double(chunks))
        }

        try command(0x04, 0x02)
    }
}

/// Cổng HID màn hình (interface 2). Chạy run loop của thread hiện tại trong lúc chờ ACK.
private final class LCDChannel {
    private let device: IOHIDDevice
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private let runLoop = CFRunLoopGetCurrent()!
    fileprivate var acked = false

    init() throws {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: LT104.vendorID,
            kIOHIDProductIDKey: LT104.productID,
            kIOHIDPrimaryUsagePageKey: LT104.lcdUsagePage,
        ] as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let dev = devices.first else {
            reportBuffer.deallocate()
            throw LT104Error.lcdNotFound
        }
        device = dev
        let r = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            reportBuffer.deallocate()
            throw LT104Error.io(tr("Opening screen interface", "Mở cổng màn hình", "打开屏幕接口"), r)
        }
        IOHIDDeviceRegisterInputReportCallback(dev, reportBuffer, 64, { ctx, _, _, _, _, _, _ in
            Unmanaged<LCDChannel>.fromOpaque(ctx!).takeUnretainedValue().acked = true
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(dev, runLoop, CFRunLoopMode.defaultMode.rawValue)
    }

    func write(_ chunk: Data) throws {
        acked = false
        let r = chunk.withUnsafeBytes { buf in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0,
                                 buf.bindMemory(to: UInt8.self).baseAddress!, buf.count)
        }
        guard r == kIOReturnSuccess else { throw LT104Error.io(tr("Sending screen data", "Gửi dữ liệu màn hình", "发送屏幕数据"), r) }
    }

    func waitForAck(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !acked {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return false }
            CFRunLoopRunInMode(.defaultMode, left, true)
        }
        return true
    }

    func close() {
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 64, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        reportBuffer.deallocate()
    }
}
