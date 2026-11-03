import Foundation
import ServiceManagement

/// Chạy không cần UI:
///   YuhKeyScreen --sync
///   YuhKeyScreen --upload <file> [--fit]
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
            case "--upload" where args.count >= 2:
                let mode: ScaleMode = args.contains("--fit") ? .fit : .fill
                let anim = try LCDAnimation.load(from: URL(fileURLWithPath: args[1]), mode: mode)
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
                print("Usage: YuhKeyScreen --sync | --upload <file> [--fit] | --launch-at-login on|off")
                exit(2)
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
