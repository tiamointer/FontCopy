import Foundation

public enum FontInstallStatus: String, Codable, CaseIterable, Sendable {
    case installed
    case missing
    case unsupported
    case conflict
    case installing
    case error

    public var displayName: String {
        switch self {
        case .installed: return "已安装"
        case .missing: return "未安装"
        case .unsupported: return "不支持"
        case .conflict: return "版本冲突"
        case .installing: return "安装中"
        case .error: return "安装失败"
        }
    }

    public var isInstallable: Bool {
        self == .missing || self == .error
    }

    /// Conflicts are not offered by the plain install actions, but an explicit
    /// update replaces the installed copy with the library file.
    public var acceptsInstall: Bool {
        isInstallable || self == .conflict
    }
}
