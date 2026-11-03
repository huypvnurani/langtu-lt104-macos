import Foundation
import ServiceManagement
import XPC

/// Chạy không cần UI:
///   YuhKeyScreen --sync
///   YuhKeyScreen --upload <file>... [--fit] [--delay <giây mỗi ảnh>]
///   YuhKeyScreen --launch-at-login on|off
enum CommandLineMode {
    static func runIfRequested() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first, cmd.hasPrefix("--") else { return }
        do {
            switch cmd {
            case "--sync":
                try LT104().syncClock()
                print("Clock synced.")
            case "--background-sync":
                // launchd gọi khi đăng nhập, mỗi giờ và khi cắm bàn phím. Phải nhận event IOKit,
                // nếu không launchd sẽ chạy lại liên tục; đợi thêm cho bàn phím kịp sẵn sàng sau khi cắm.
                xpc_set_event_stream_handler("com.apple.iokit.matching", .main) { _ in }
                RunLoop.main.run(until: Date().addingTimeInterval(2))
                guard LT104.isConnected else { exit(0) }
                try LT104().syncClock()
            case "--upload" where args.count >= 2:
                let mode: ScaleMode = args.contains("--fit") ? .fit : .fill
                var delay = 1.0
                var files: [URL] = []
                var rest = args.dropFirst()
                while let a = rest.popFirst() {
                    if a == "--fit" { continue }
                    if a == "--delay", let v = rest.popFirst().flatMap(Double.init) { delay = v; continue }
                    files.append(URL(fileURLWithPath: a))
                }
                let sources = try files.map(SourceImage.load)
                guard let anim = LCDAnimation.build(from: sources, mode: mode, slideDelay: delay) else { exit(2) }
                print("\(anim.frames.count) frames, \(anim.chunkCount) chunks, ~\(anim.estimatedUploadSeconds)s")
                var lastPct = -1
                try LT104().uploadAnimation(anim.encode()) { p in
                    let pct = Int(p * 100)
                    if pct / 10 != lastPct / 10 { print("\(pct)%"); lastPct = pct }
                }
                print("Done.")
            case "--launch-at-login" where args.count >= 2:
                if args[1] == "on" {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                print("Launch at login: \(SMAppService.mainApp.status == .enabled ? "on" : "off")")
            default:
                print("Usage: YuhKeyScreen --sync | --upload <file>... [--fit] [--delay <seconds>] | --launch-at-login on|off")
                exit(2)
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
