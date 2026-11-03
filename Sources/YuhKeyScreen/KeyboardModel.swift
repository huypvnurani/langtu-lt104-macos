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
        didSet {
            UserDefaults.standard.set(autoSync, forKey: "autoSync")
            applyBackgroundSync()
        }
    }
    /// Tắt: app là cửa sổ bình thường, đóng cửa sổ là thoát. Bật: ở lại trên menu bar.
    @Published var showInMenuBar = KeyboardModel.showsInMenuBar {
        didSet {
            UserDefaults.standard.set(showInMenuBar, forKey: "showInMenuBar")
            NSApp.setActivationPolicy(showInMenuBar ? .accessory : .regular)
            if !showInMenuBar && launchAtLogin { launchAtLogin = false }
        }
    }
    static var showsInMenuBar: Bool { UserDefaults.standard.bool(forKey: "showInMenuBar") }
    @Published var scaleMode = ScaleMode(rawValue: UserDefaults.standard.string(forKey: "scaleMode") ?? "") ?? .fill {
        didSet {
            UserDefaults.standard.set(scaleMode.rawValue, forKey: "scaleMode")
            rebuild()
        }
    }
    /// Các ảnh sẽ ghép thành animation, theo đúng thứ tự hiện.
    @Published private(set) var sources: [SourceImage] = []
    @Published var selectedSource = 0
    /// Mỗi ảnh tĩnh hiện bao lâu khi ghép nhiều ảnh (giây).
    @Published var slideDelay = UserDefaults.standard.object(forKey: "slideDelay") as? Double ?? 1.0 {
        didSet {
            UserDefaults.standard.set(slideDelay, forKey: "slideDelay")
            rebuild()
        }
    }
    @Published private(set) var animation: LCDAnimation?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet { applyLaunchAtLogin() }
    }

    var isBusy: Bool { uploadProgress != nil }

    /// Mọi lệnh tới bàn phím chạy tuần tự ở đây.
    private let deviceQueue = DispatchQueue(label: "solutions.urani.YuhKeyScreen.device")
    private var notifyPort: IONotificationPortRef?
    private var hotplugIterators: [io_iterator_t] = []

    /// Đồng bộ giờ khi app đã thoát (Resources/solutions.urani.YuhKeyScreen.sync.plist):
    /// launchd chạy `--background-sync` khi đăng nhập, mỗi giờ và khi cắm bàn phím.
    private static let backgroundSync = SMAppService.agent(plistName: "solutions.urani.YuhKeyScreen.sync.plist")

    static let shared = KeyboardModel()

    private init() {}

    /// Gọi sau khi app khởi động xong, không gọi trong lúc SwiftUI dựng scene
    /// (đổi @Published lúc đó làm SwiftUI cập nhật lặp vô hạn).
    func start() {
        watchHotplug()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.autoSyncSoon(after: 3) }
        }
        if autoSync && Self.backgroundSync.status != .enabled { applyBackgroundSync() }
        // Mở cùng macOS chỉ có ý nghĩa ở chế độ menu bar.
        if !showInMenuBar && launchAtLogin { launchAtLogin = false }
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

    /// Thay toàn bộ danh sách (nút chọn ảnh).
    func replaceSources(with urls: [URL]) {
        sources = []
        addSources(urls)
    }

    /// Thêm vào cuối danh sách (kéo thả, nút thêm ảnh). Nhiều file thì xếp theo tên.
    func addSources(_ urls: [URL]) {
        var failed: [String] = []
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let firstNew = sources.count
        for url in sorted {
            if let img = try? SourceImage.load(url) {
                sources.append(img)
            } else {
                failed.append(url.lastPathComponent)
            }
        }
        if sources.count > firstNew { selectedSource = firstNew }
        rebuild()
        if !failed.isEmpty {
            status = ImageLoadError.unreadable(failed.joined(separator: ", ")).localizedDescription
        }
    }

    func removeSource(at i: Int) {
        guard sources.indices.contains(i) else { return }
        sources.remove(at: i)
        selectedSource = min(selectedSource, max(0, sources.count - 1))
        rebuild()
    }

    func moveSource(at i: Int, by delta: Int) {
        let j = i + delta
        guard sources.indices.contains(i), sources.indices.contains(j) else { return }
        sources.swapAt(i, j)
        selectedSource = j
        rebuild()
    }

    func setOffset(_ offset: CGPoint, forSource i: Int) {
        guard sources.indices.contains(i) else { return }
        sources[i].offset = offset
        rebuild()
    }

    /// Zoom đang kéo slider: chỉ khung xem trước dùng, thả tay mới dựng lại animation.
    @Published var previewZoom: Double?

    func setZoom(_ zoom: Double, forSource i: Int) {
        guard sources.indices.contains(i) else { return }
        previewZoom = nil
        let z = min(SourceImage.zoomRange.upperBound, max(SourceImage.zoomRange.lowerBound, zoom))
        guard z != sources[i].zoom else { return }
        sources[i].zoom = z
        rebuild()
    }

    /// Ảnh đang chỉnh được (vị trí, zoom): ảnh duy nhất, hoặc ảnh được chọn khi dừng phát.
    func editableSource(playing: Bool) -> Int? {
        let i = sources.count == 1 ? 0 : (playing ? -1 : selectedSource)
        return sources.indices.contains(i) ? i : nil
    }

    private func rebuild() {
        animation = LCDAnimation.build(from: sources, mode: scaleMode, slideDelay: slideDelay)
        status = animation?.truncated == true
            ? tr("More than \(LCDAnimation.maxFrames) frames in total, only the first \(LCDAnimation.maxFrames) are used.",
                 "Tổng cộng hơn \(LCDAnimation.maxFrames) khung, chỉ lấy \(LCDAnimation.maxFrames) khung đầu.",
                 "总帧数超过 \(LCDAnimation.maxFrames) 帧，只使用前 \(LCDAnimation.maxFrames) 帧。")
            : nil
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

    // MARK: - Chạy nền / mở cùng macOS

    private func applyBackgroundSync() {
        do {
            if autoSync {
                try Self.backgroundSync.register()
            } else {
                try Self.backgroundSync.unregister()
            }
        } catch {
            status = tr("Couldn't change background sync: ", "Không bật/tắt được đồng bộ nền: ", "无法更改后台同步：") + error.localizedDescription
        }
        if autoSync && Self.backgroundSync.status == .requiresApproval {
            status = tr("Allow YuhKeyScreen in System Settings → General → Login Items so it can sync in the background.",
                        "Hãy cho phép YuhKeyScreen trong System Settings → General → Login Items để đồng bộ nền.",
                        "请在 系统设置 → 通用 → 登录项 中允许 YuhKeyScreen 在后台运行。")
            SMAppService.openSystemSettingsLoginItems()
        }
    }

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
