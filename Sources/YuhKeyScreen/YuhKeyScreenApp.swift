import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct YuhKeyScreenApp: App {
    @StateObject private var model = KeyboardModel()

    init() {
        CommandLineMode.runIfRequested()
    }

    var body: some Scene {
        MenuBarExtra("YuhKeyScreen", systemImage: "keyboard") {
            PanelView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct PanelView: View {
    @EnvironmentObject private var model: KeyboardModel
    @State private var dropTargeted = false

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
            HStack {
                Toggle(tr("Launch at login", "Mở cùng macOS", "登录时启动"), isOn: $model.launchAtLogin)
                    .toggleStyle(.checkbox)
                Spacer()
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
            Toggle(tr("Auto-sync on plug-in, on wake and every hour", "Tự đồng bộ khi cắm, khi máy thức dậy và mỗi giờ", "插入、唤醒时及每小时自动同步"), isOn: $model.autoSync)
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

            preview
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { model.select(url) } }
                    }
                    return true
                }

            HStack {
                Button(tr("Choose image/GIF…", "Chọn ảnh/GIF…", "选择图片/GIF…"), action: pickFile)
                Spacer()
                Picker("", selection: $model.scaleMode) {
                    ForEach(ScaleMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }
            .disabled(model.isBusy)

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

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black)
            if let anim = model.animation {
                AnimationPreview(animation: anim)
            } else {
                Text(tr("Drop an image or GIF here", "Kéo thả ảnh hoặc GIF vào đây", "将图片或 GIF 拖到这里"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: 2)
            }
        }
        .frame(width: 320, height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .frame(maxWidth: .infinity)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif, .png, .jpeg, .webP, .heic, .image]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            model.select(url)
        }
    }
}

/// Phát lại animation đúng nhịp delay sẽ chạy trên bàn phím.
private struct AnimationPreview: View {
    let animation: LCDAnimation

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.01)) { context in
            Image(decorative: animation.frames[frameIndex(at: context.date)], scale: 1)
                .resizable()
                .interpolation(.none)
        }
    }

    private func frameIndex(at date: Date) -> Int {
        let total = animation.totalDuration
        guard animation.frames.count > 1, total > 0 else { return 0 }
        var t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: total)
        for (i, d) in animation.delays.enumerated() {
            t -= Double(d) / 100
            if t < 0 { return i }
        }
        return animation.frames.count - 1
    }
}
