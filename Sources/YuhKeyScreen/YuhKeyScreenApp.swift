import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct YuhKeyScreenApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @ObservedObject private var model = KeyboardModel.shared

    init() {
        CommandLineMode.runIfRequested()
    }

    var body: some Scene {
        Window("YuhKeyScreen", id: "main") {
            PanelView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("YuhKeyScreen", systemImage: "keyboard", isInserted: Binding(
            // MenuBarExtra ghi lại binding liên tục; chỉ nhận khi giá trị thật sự đổi để tránh vòng lặp cập nhật.
            get: { model.showInMenuBar },
            set: { if $0 != model.showInMenuBar { model.showInMenuBar = $0 } }
        )) {
            PanelView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(KeyboardModel.showsInMenuBar ? .accessory : .regular)
        DispatchQueue.main.async { MainActor.assumeIsolated { KeyboardModel.shared.start() } }
        if KeyboardModel.showsInMenuBar {
            // Chế độ menu bar (kể cả khi mở cùng macOS): chỉ hiện biểu tượng, không bật cửa sổ.
            DispatchQueue.main.async {
                NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") == true }.forEach { $0.close() }
            }
        } else {
            NSApp.activate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !KeyboardModel.showsInMenuBar
    }
}

struct PanelView: View {
    @EnvironmentObject private var model: KeyboardModel
    @Environment(\.openWindow) private var openWindow
    @State private var dropTargeted = false
    /// Khi ghép nhiều ảnh: đang phát thử, hay đang dừng ở ảnh được chọn để chỉnh vị trí.
    @State private var playing = true

    /// Tắt menu bar thì mở cửa sổ trước, để app không thoát khi panel menu bar đóng lại.
    private var menuBarBinding: Binding<Bool> {
        Binding(get: { model.showInMenuBar }, set: { on in
            if !on {
                openWindow(id: "main")
                NSApp.activate()
            }
            model.showInMenuBar = on
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            clockSection
            Divider()
            screenSection
            if let status = model.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(tr("Show in menu bar", "Hiện trên menu bar", "在菜单栏显示"), isOn: menuBarBinding)
                    if model.showInMenuBar {
                        Toggle(tr("Launch at login", "Mở cùng macOS", "登录时启动"), isOn: $model.launchAtLogin)
                    }
                }
                .toggleStyle(.checkbox)
                Spacer()
                Button(tr("About", "Giới thiệu", "关于")) {
                    NSApp.activate()
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
                Button(tr("Quit", "Thoát", "退出")) { NSApp.terminate(nil) }
            }
            .font(.callout)
        }
        .padding(16)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("LANGTU LT104").font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.connected ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(model.connected ? tr("Connected via USB", "Đã kết nối USB", "已通过 USB 连接") : tr("USB cable not connected", "Chưa cắm dây USB", "未连接 USB 数据线"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var clockSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(tr("Clock", "Đồng hồ", "时钟"), systemImage: "clock")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(tr("Sync now", "Đồng bộ giờ ngay", "立即同步")) { model.syncClock() }
                    .disabled(!model.connected || model.isBusy)
            }
            Toggle(tr("Auto-sync on plug-in, at login and every hour — even after quitting the app", "Tự đồng bộ khi cắm, khi đăng nhập và mỗi giờ, kể cả khi đã thoát app", "插入、登录时及每小时自动同步，退出应用后依然有效"), isOn: $model.autoSync)
                .toggleStyle(.checkbox)
                .font(.callout)
            if let last = model.lastSync {
                Text(tr("Last sync: ", "Lần cuối: ", "上次同步：") + last.formatted(date: .omitted, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var screenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(tr("Screen", "Màn hình", "屏幕"), systemImage: "photo")
                .font(.subheadline.weight(.semibold))

            ScreenPreview(dropTargeted: dropTargeted, playing: playing)
                .frame(maxWidth: .infinity)
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    loadURLs(providers) { model.addSources($0) }
                    return true
                }

            if model.sources.count > 1 {
                SlideStrip(playing: $playing)
            }

            HStack {
                Button(tr("Choose images…", "Chọn ảnh…", "选择图片…")) { pickFiles(replace: true) }
                Button(tr("Add…", "Thêm ảnh…", "添加…")) { pickFiles(replace: false) }
                    .disabled(model.sources.isEmpty)
                Spacer()
                Picker("", selection: $model.scaleMode) {
                    ForEach(ScaleMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
            }
            .disabled(model.isBusy)

            if model.scaleMode == .fill, let i = model.editableSource(playing: playing) {
                ZoomControl(index: i)
                    .disabled(model.isBusy)
            }

            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let anim = model.animation {
                Text(tr("\(anim.frames.count) frames · about \(anim.estimatedUploadSeconds)s to upload", "\(anim.frames.count) khung · nạp mất khoảng \(anim.estimatedUploadSeconds) giây", "\(anim.frames.count) 帧 · 上传约需 \(anim.estimatedUploadSeconds) 秒"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let p = model.uploadProgress {
                ProgressView(value: p) {
                    Text(tr("Uploading… \(Int(p * 100))% (backlight turns off meanwhile)", "Đang nạp… \(Int(p * 100))% (đèn bàn phím sẽ tắt tạm)", "上传中… \(Int(p * 100))%（期间背光会暂时关闭）"))
                        .font(.caption)
                }
            } else {
                Button {
                    model.upload()
                } label: {
                    Text(tr("Upload to keyboard", "Nạp vào bàn phím", "上传到键盘")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.animation == nil || !model.connected)
            }
        }
    }

    private var hint: String? {
        guard !model.sources.isEmpty else { return nil }
        if model.sources.count > 1 && playing {
            return tr("Pause and pick an image below to reposition it.",
                      "Bấm dừng rồi chọn một ảnh bên dưới để chỉnh vị trí.",
                      "暂停后选择下方的图片即可调整位置。")
        }
        guard let i = model.editableSource(playing: playing),
              model.sources[i].canPan(model.scaleMode, zoom: model.previewZoom) else { return nil }
        return tr("Drag the image to reposition · double-click to center",
                  "Kéo ảnh trong khung để chỉnh vị trí · bấm đúp để căn giữa",
                  "拖动图片调整位置 · 双击居中")
    }

    private func pickFiles(replace: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif, .png, .jpeg, .webP, .heic, .image]
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        if replace {
            playing = true
            model.replaceSources(with: panel.urls)
        } else {
            model.addSources(panel.urls)
        }
    }

    private func loadURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { if !urls.isEmpty { done(urls) } }
    }
}

/// Khung xem trước 2x. Vẽ thẳng từ ảnh gốc với cùng phép đặt vị trí như lúc dựng animation,
/// nên kéo ảnh thấy ngay kết quả mà không phải dựng lại cả animation.
private struct ScreenPreview: View {
    @EnvironmentObject private var model: KeyboardModel
    let dropTargeted: Bool
    let playing: Bool

    @State private var dragOffset: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var cursorPushed = false

    private static let scale: CGFloat = 2
    private static let size = CGSize(width: CGFloat(LCDAnimation.width) * scale, height: CGFloat(LCDAnimation.height) * scale)

    /// Ảnh đang chỉnh vị trí được: ảnh duy nhất, hoặc ảnh được chọn khi đang dừng.
    private var panTarget: Int? {
        guard let i = model.editableSource(playing: playing),
              model.sources[i].canPan(model.scaleMode, zoom: zoom(of: i)) else { return nil }
        return i
    }

    /// Zoom đang hiện của ảnh i (kể cả lúc đang kéo slider).
    private func zoom(of i: Int) -> Double {
        (i == model.editableSource(playing: playing) ? model.previewZoom : nil) ?? model.sources[i].zoom
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let anim = model.animation, !model.sources.isEmpty {
                if model.sources.count > 1 && !playing {
                    frame(source: model.selectedSource, index: 0)
                } else {
                    TimelineView(.animation(minimumInterval: 0.01, paused: anim.frames.count < 2)) { ctx in
                        let o = anim.origins[frameIndex(anim, at: ctx.date)]
                        frame(source: o.source, index: o.frame)
                    }
                }
            } else {
                Text(tr("Drop images or GIFs here", "Kéo thả ảnh hoặc GIF vào đây", "将图片或 GIF 拖到这里"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: Self.size.width, height: Self.size.height)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if let t = panTarget { model.setOffset(.zero, forSource: t) }
        }
        .gesture(panGesture, including: panTarget == nil ? .none : .all)
        .onHover { inside in setHandCursor(inside && panTarget != nil) }
        .onChange(of: panTarget) { _, t in if t == nil { setHandCursor(false) } }
    }

    @ViewBuilder
    private func frame(source s: Int, index f: Int) -> some View {
        if model.sources.indices.contains(s), model.sources[s].frames.indices.contains(f) {
            let src = model.sources[s]
            let offset = (s == panTarget ? dragOffset : nil) ?? src.offset
            let r = LCDAnimation.placement(of: src.size, mode: model.scaleMode, offset: offset, zoom: zoom(of: s))
            Image(decorative: src.frames[f], scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: r.width * Self.scale, height: r.height * Self.scale)
                .offset(x: r.minX * Self.scale, y: r.minY * Self.scale)
        }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { g in
                guard let t = panTarget else { return }
                let src = model.sources[t]
                if dragStart == nil {
                    dragStart = src.offset
                    NSCursor.closedHand.set()
                }
                let base = LCDAnimation.placement(of: src.size, mode: model.scaleMode, offset: .zero, zoom: zoom(of: t))
                let overflowX = base.width - CGFloat(LCDAnimation.width)
                let overflowY = base.height - CGFloat(LCDAnimation.height)
                // Kéo ảnh sang phải thì mép trái lộ ra, tức là offset giảm.
                func axis(_ start: CGFloat, _ moved: CGFloat, _ overflow: CGFloat) -> CGFloat {
                    guard overflow > 0.5 else { return 0 }
                    return min(1, max(-1, start - 2 * (moved / Self.scale) / overflow))
                }
                dragOffset = CGPoint(x: axis(dragStart!.x, g.translation.width, overflowX),
                                     y: axis(dragStart!.y, g.translation.height, overflowY))
            }
            .onEnded { _ in
                if let t = panTarget, let o = dragOffset { model.setOffset(o, forSource: t) }
                dragOffset = nil
                dragStart = nil
                if cursorPushed { NSCursor.openHand.set() }
            }
    }

    private func setHandCursor(_ on: Bool) {
        if on && !cursorPushed {
            NSCursor.openHand.push()
            cursorPushed = true
        } else if !on && cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }

    private func frameIndex(_ anim: LCDAnimation, at date: Date) -> Int {
        let total = anim.totalDuration
        guard anim.frames.count > 1, total > 0 else { return 0 }
        var t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: total)
        for (i, d) in anim.delays.enumerated() {
            t -= Double(d) / 100
            if t < 0 { return i }
        }
        return anim.frames.count - 1
    }
}

/// Zoom ở chế độ lấp đầy: slider nhảy theo số tròn, ô % gõ tay được tới 2 số lẻ.
private struct ZoomControl: View {
    @EnvironmentObject private var model: KeyboardModel
    let index: Int

    private static let percentFormat = FloatingPointFormatStyle<Double>.number
        .precision(.fractionLength(0...2))
        .locale(Locale(identifier: "en_US_POSIX"))

    private var zoom: Double { model.previewZoom ?? model.sources[index].zoom }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { zoom * 100 }, set: { model.previewZoom = $0.rounded() / 100 }),
                in: SourceImage.zoomRange.lowerBound * 100 ... SourceImage.zoomRange.upperBound * 100,
                step: 1
            ) { editing in
                if !editing, let z = model.previewZoom { model.setZoom(z, forSource: index) }
            }
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("", value: Binding(
                get: { (zoom * 10_000).rounded() / 100 },
                set: { model.setZoom(($0 * 100).rounded() / 10_000, forSource: index) }
            ), format: Self.percentFormat)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 62)
            Text("%")
        }
        .font(.callout)
        .help(tr("Zoom: 100% fills the screen", "Zoom: 100% là vừa lấp đầy màn hình", "缩放：100% 为刚好填满屏幕"))
    }
}

/// Dải ảnh nhỏ khi ghép nhiều ảnh: chọn, đổi thứ tự, xoá, phát thử, thời gian mỗi ảnh.
private struct SlideStrip: View {
    @EnvironmentObject private var model: KeyboardModel
    @Binding var playing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(model.sources.enumerated()), id: \.element.id) { i, src in
                        thumbnail(src, selected: !playing && i == model.selectedSource)
                            .onTapGesture {
                                model.selectedSource = i
                                playing = false
                            }
                            .help(src.name)
                    }
                }
                .padding(2)
            }

            HStack(spacing: 8) {
                Button { playing.toggle() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                }
                .help(playing ? tr("Pause", "Dừng", "暂停") : tr("Play", "Phát thử", "播放"))
                Button { model.moveSource(at: model.selectedSource, by: -1) } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(playing || model.selectedSource == 0)
                .help(tr("Move earlier", "Đưa lên trước", "前移"))
                Button { model.moveSource(at: model.selectedSource, by: 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(playing || model.selectedSource >= model.sources.count - 1)
                .help(tr("Move later", "Đưa ra sau", "后移"))
                Button { model.removeSource(at: model.selectedSource) } label: {
                    Image(systemName: "trash")
                }
                .disabled(playing)
                .help(tr("Remove", "Xoá ảnh này", "移除"))
                Spacer()
                Stepper(value: $model.slideDelay, in: 0.1...5, step: 0.1) {
                    Text(tr("Each image ", "Mỗi ảnh ", "每张 ") + String(format: "%.1fs", model.slideDelay))
                        .font(.caption)
                        .monospacedDigit()
                }
                .help(tr("How long each still image stays on screen", "Mỗi ảnh tĩnh hiện bao lâu", "每张静态图片显示的时长"))
            }
            .buttonStyle(.borderless)
            .disabled(model.isBusy)
        }
    }

    private func thumbnail(_ src: SourceImage, selected: Bool) -> some View {
        Image(decorative: src.frames[0], scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 56, height: 28)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .bottomTrailing) {
                if src.delays != nil {
                    Text("GIF")
                        .font(.system(size: 7, weight: .bold))
                        .padding(.horizontal, 2)
                        .background(Color.black.opacity(0.6))
                        .foregroundStyle(.white)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 1)
            }
    }
}
