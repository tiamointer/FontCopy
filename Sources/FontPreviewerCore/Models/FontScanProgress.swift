import Foundation

public struct FontScanProgress: Equatable, Sendable {
    public let processed: Int
    public let total: Int
    public let currentPath: String?

    public init(processed: Int, total: Int, currentPath: String?) {
        self.processed = processed
        self.total = total
        self.currentPath = currentPath
    }

    public var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(processed) / Double(total)))
    }

    public var displayText: String {
        if total == 0 {
            return "扫描字体中 0/0"
        }
        return "扫描字体中 \(processed)/\(total)"
    }
}
