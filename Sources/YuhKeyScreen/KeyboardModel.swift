import AppKit
import Foundation
import IOKit
import ServiceManagement

@MainActor
final class KeyboardModel: ObservableObject {
    @Published private(set) var connected = LT104.isConnected
    @Published private(set) var lastSync: Date?
    @Published private(set) var status: String?
    @Published private(set) var uploadProgress: Double?

    @Published var autoSync = UserDefaults.standard.object(forKey: "autoSync") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSync, forKey: "autoSync") }
    }
    @Published var scaleMode = ScaleMode(rawValue: UserDefaults.standard.string(forKey: "scaleMode") ?? "") ?? .fill {
        didSet {
            UserDefaults.standard.set(scaleMode.rawValue, forKey: "scaleMode")
            reloadSelection()
        }
    }
    @Published private(set) var selectedURL: URL?
    @Published private(set) var animation: LCDAnimation?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet { applyLaunchAtLogin() }
    }

    var isBusy: Bool { uploadProgress != nil }

    /// Mọi lệnh tới bàn phím chạy tuần tự ở đây.
    private let deviceQueue = DispatchQueue(label: "solutions.urani.YuhKeyScreen.device")
    private var notifyPort: IONotificationPortRef?
    private var hotplugIterators: [io_iterator_t] = []
    private var timer: Timer?

    /// Đồng hồ trên bàn phím tự chạy và trôi dần, nên đồng bộ lại định kỳ.
    private static let resyncInterval: TimeInterval = 60 * 60

    init() {
        watchHotplug()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.autoSyncSoon(after: 3) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.resyncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoSyncSoon(after: 0) }
        }
        autoSyncSoon(after: 1)
    }

    // MARK: - Đồng hồ

    func syncClock(silent: Bool = false) {
        guard !isBusy else { return }
        deviceQueue.async {
            let result = Result { try LT104().syncClock() }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.lastSync = Date()
                    if !silent { self.status = nil }
                case let .failure(err):
                    if !silent { self.status = err.localizedDescription }
                }
            }
        }
    }

    private func autoSyncSoon(after delay: TimeInterval) {
        guard autoSync else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if self.connected { self.syncClock(silent: true) }
        }
    }

    // MARK: - Màn hình

    func select(_ url: URL) {
        selectedURL = url
        reloadSelection()
    }

    private func reloadSelection() {
        guard let url = selectedURL else { return }
        do {
            animation = try LCDAnimation.load(from: url, mode: scaleMode)
            status = animation!.truncated ? tr("The file has more than \(LCDAnimation.maxFrames) frames, only the first \(LCDAnimation.maxFrames) are used.", "File có hơn \(LCDAnimation.maxFrames) khung, chỉ lấy \(LCDAnimation.maxFrames) khung đầu.", "文件超过 \(LCDAnimation.maxFrames) 帧，只使用前 \(LCDAnimation.maxFrames) 帧。") : nil
        } catch {
            animation = nil
            status = error.localizedDescription
        }
    }

    func upload() {
        guard let animation, !isBusy else { return }
        let payload = animation.encode()
        uploadProgress = 0
        status = nil
        deviceQueue.async {
            let result = Result {
                try LT104().uploadAnimation(payload) { p in
                    DispatchQueue.main.async { self.uploadProgress = p }
                }
            }
            DispatchQueue.main.async {
                self.uploadProgress = nil
                switch result {
                case .success: self.status = tr("Uploaded \(animation.frames.count) frames to the keyboard.", "Đã nạp \(animation.frames.count) khung vào bàn phím.", "已上传 \(animation.frames.count) 帧到键盘。")
                case let .failure(err): self.status = err.localizedDescription
                }
            }
        }
    }

    // MARK: - Cắm / rút bàn phím

    private func watchHotplug() {
        let port = IONotificationPortCreate(kIOMainPortDefault)!
        notifyPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iter: io_iterator_t = 0
            IOServiceAddMatchingNotification(port, type, LT104.matchingDictionary(), { ctx, iter in
                drain(iter)
                let model = Unmanaged<KeyboardModel>.fromOpaque(ctx!).takeUnretainedValue()
                MainActor.assumeIsolated { model.deviceChanged() }
            }, ctx, &iter)
            drain(iter) // phải đọc hết iterator thì mới nhận được thông báo tiếp theo
            hotplugIterators.append(iter)
        }
    }

    private func deviceChanged() {
        let now = LT104.isConnected
        let plugged = now && !connected
        connected = now
        if plugged { autoSyncSoon(after: 1.5) }
    }

    // MARK: - Mở cùng macOS

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            status = tr("Couldn't change launch at login: ", "Không bật/tắt được mở cùng macOS: ", "无法更改登录时启动：") + error.localizedDescription
        }
    }
}

private func drain(_ iter: io_iterator_t) {
    while case let obj = IOIteratorNext(iter), obj != 0 { IOObjectRelease(obj) }
}
