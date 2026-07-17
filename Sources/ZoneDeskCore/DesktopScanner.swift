import Foundation

public struct DesktopScanner {
    public var fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func scan(directory: URL) throws -> [DesktopFile] {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isHiddenKey, .isDirectoryKey],
            options: [.skipsPackageDescendants]
        )

        return urls.compactMap { url in
            guard !url.lastPathComponent.hasPrefix(".") else {
                return nil
            }

            let finderInfo = (try? FinderInfoXattrStore.readOrEmpty(from: url))
                ?? Data(repeating: 0, count: FinderInfoCodec.finderInfoByteCount)
            let iconPosition = (try? FinderInfoCodec.readLocation(from: finderInfo))
                ?? FinderIconPoint(x: 0, y: 0)

            return DesktopFile(
                url: url,
                category: DesktopFileClassifier.classify(url: url),
                iconPosition: iconPosition
            )
        }
        .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    public static func desktopURL() -> URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }
}
