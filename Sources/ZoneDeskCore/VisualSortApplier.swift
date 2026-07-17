import Foundation

public struct VisualSortApplyReport: Equatable, Sendable {
    public var applied: Int
    public var failures: [String]

    public init(applied: Int, failures: [String]) {
        self.applied = applied
        self.failures = failures
    }
}

public enum VisualSortApplier {
    public static func apply(_ moves: [VisualSortMove]) -> VisualSortApplyReport {
        var applied = 0
        var failures: [String] = []

        for move in moves {
            do {
                let original = try FinderInfoXattrStore.readOrEmpty(from: move.file.url)
                let updated = try FinderInfoCodec.replacingLocation(move.target, in: original)
                try FinderInfoXattrStore.write(updated, to: move.file.url)
                notifyFinderIconChanged(path: move.file.url.path)
                applied += 1
            } catch {
                failures.append("\(move.file.url.path): \(error)")
            }
        }

        return VisualSortApplyReport(applied: applied, failures: failures)
    }

    public static func notifyFinderIconChanged(path: String) {
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.apple.finder.iconChanged"),
            object: path
        )
    }
}
