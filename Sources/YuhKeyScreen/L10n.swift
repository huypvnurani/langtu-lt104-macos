import Foundation

/// Ngôn ngữ giao diện, chọn theo thứ tự ngôn ngữ ưu tiên của macOS. Mặc định tiếng Anh.
enum UILanguage {
    case en, vi, zh

    static let current: UILanguage = {
        for id in Locale.preferredLanguages {
            if id.hasPrefix("vi") { return .vi }
            if id.hasPrefix("zh") { return .zh }
            if id.hasPrefix("en") { return .en }
        }
        return .en
    }()
}

func tr(_ en: String, _ vi: String, _ zh: String) -> String {
    switch UILanguage.current {
    case .en: return en
    case .vi: return vi
    case .zh: return zh
    }
}
