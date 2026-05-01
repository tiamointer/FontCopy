import Foundation

public struct FontNormalizeProgress: Equatable, Sendable {
    public let processed: Int
    public let total: Int
    public let success: Int
    public let skipped: Int
    public let failed: Int
    public let currentName: String?

    public init(
        processed: Int,
        total: Int,
        success: Int,
        skipped: Int,
        failed: Int,
        currentName: String?
    ) {
        self.processed = processed
        self.total = total
        self.success = success
        self.skipped = skipped
        self.failed = failed
        self.currentName = currentName
    }

    public var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(processed) / Double(total)))
    }

    public var displayText: String {
        if total == 0 {
            return "规范化中 0/0"
        }
        var text = "规范化中 \(processed)/\(total) · 成功 \(success)"
        if skipped > 0 { text += " · 跳过 \(skipped)" }
        if failed > 0 { text += " · 失败 \(failed)" }
        return text
    }
}

public enum FontInstallPhase: String, Sendable, Equatable {
    case staging
    case applying
    case verifying
}

public struct FontInstallProgress: Equatable, Sendable {
    public let phase: FontInstallPhase
    public let processed: Int
    public let total: Int
    public let currentName: String?

    public init(phase: FontInstallPhase, processed: Int, total: Int, currentName: String?) {
        self.phase = phase
        self.processed = processed
        self.total = total
        self.currentName = currentName
    }

    public var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(processed) / Double(total)))
    }

    public var displayText: String {
        switch phase {
        case .staging:
            if total == 0 {
                return "正在准备安装..."
            }
            return "暂存到临时目录 \(processed)/\(total)"
        case .applying:
            return "等待管理员授权并写入 /Library/Fonts..."
        case .verifying:
            return "正在校验已安装的字体..."
        }
    }
}
