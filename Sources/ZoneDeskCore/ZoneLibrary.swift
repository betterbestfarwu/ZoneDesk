import Foundation

public struct ZoneStoredFile: Equatable, Sendable {
    public var url: URL
    public var displayName: String
    public var category: FileCategory
    public var isDirectory: Bool
    public var fileSize: Int?
    public var lastOpenedDate: Date?
    public var dateAdded: Date?
    public var modificationDate: Date?
    public var creationDate: Date?
    public var tagNames: [String]

    public init(
        url: URL,
        displayName: String,
        category: FileCategory,
        isDirectory: Bool = false,
        fileSize: Int? = nil,
        lastOpenedDate: Date? = nil,
        dateAdded: Date? = nil,
        modificationDate: Date? = nil,
        creationDate: Date? = nil,
        tagNames: [String] = []
    ) {
        self.url = url
        self.displayName = displayName
        self.category = category
        self.isDirectory = isDirectory
        self.fileSize = fileSize
        self.lastOpenedDate = lastOpenedDate
        self.dateAdded = dateAdded
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.tagNames = tagNames
    }
}

struct ZoneFileResourceValues {
    var isHidden: Bool?
    var isDirectory: Bool?
    var fileSize: Int?
    var lastOpenedDate: Date?
    var dateAdded: Date?
    var modificationDate: Date?
    var creationDate: Date?
    var tagNames: [String]?

    init(
        isHidden: Bool? = nil,
        isDirectory: Bool? = nil,
        fileSize: Int? = nil,
        lastOpenedDate: Date? = nil,
        dateAdded: Date? = nil,
        modificationDate: Date? = nil,
        creationDate: Date? = nil,
        tagNames: [String]? = nil
    ) {
        self.isHidden = isHidden
        self.isDirectory = isDirectory
        self.fileSize = fileSize
        self.lastOpenedDate = lastOpenedDate
        self.dateAdded = dateAdded
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.tagNames = tagNames
    }

    init(_ values: URLResourceValues) {
        self.init(
            isHidden: values.isHidden,
            isDirectory: values.isDirectory,
            fileSize: values.fileSize,
            lastOpenedDate: values.contentAccessDate,
            dateAdded: values.addedToDirectoryDate,
            modificationDate: values.contentModificationDate,
            creationDate: values.creationDate,
            tagNames: values.tagNames
        )
    }
}

public struct ZoneCollectionMove: Equatable, Sendable {
    public var source: URL
    public var destination: URL
    public var zoneID: UUID

    public init(source: URL, destination: URL, zoneID: UUID) {
        self.source = source
        self.destination = destination
        self.zoneID = zoneID
    }
}

public struct ZoneCollectionFailure: Equatable, Sendable {
    public var source: URL
    public var message: String

    public init(source: URL, message: String) {
        self.source = source
        self.message = message
    }
}

public struct ZoneCollectionReport: Equatable, Sendable {
    public var moves: [ZoneCollectionMove]
    public var failures: [ZoneCollectionFailure]

    public init(moves: [ZoneCollectionMove] = [], failures: [ZoneCollectionFailure] = []) {
        self.moves = moves
        self.failures = failures
    }
}

public struct ZoneRestoreMove: Equatable, Sendable {
    public var source: URL
    public var destination: URL

    public init(source: URL, destination: URL) {
        self.source = source
        self.destination = destination
    }
}

public struct ZoneRestoreFailure: Equatable, Sendable {
    public var source: URL
    public var message: String

    public init(source: URL, message: String) {
        self.source = source
        self.message = message
    }
}

public struct ZoneRestoreReport: Equatable, Sendable {
    public var moves: [ZoneRestoreMove]
    public var failures: [ZoneRestoreFailure]

    public init(moves: [ZoneRestoreMove] = [], failures: [ZoneRestoreFailure] = []) {
        self.moves = moves
        self.failures = failures
    }

    public var completed: Bool {
        failures.isEmpty
    }
}

public enum ZoneLibraryError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case destinationDirectoryExists(URL)
    case invalidItemName(String)
    case destinationItemExists(URL)
    case sourceOutsideZone(URL)
    case caseOnlyRenameRollbackFailed(
        original: URL,
        temporary: URL,
        destination: URL,
        renameFailure: String,
        rollbackFailure: String
    )

    public var description: String {
        switch self {
        case let .destinationDirectoryExists(url):
            return "Destination zone directory already exists: \(url.path)"
        case let .invalidItemName(name):
            return "Invalid stored item name: \(name)"
        case let .destinationItemExists(url):
            return "Destination item already exists: \(url.path)"
        case let .sourceOutsideZone(url):
            return "Source item is outside the zone directory: \(url.path)"
        case let .caseOnlyRenameRollbackFailed(
            original,
            temporary,
            destination,
            renameFailure,
            rollbackFailure
        ):
            return "Case-only rename failed from \(original.path) via \(temporary.path) "
                + "to \(destination.path): \(renameFailure) Rollback failed: \(rollbackFailure)"
        }
    }

    public var errorDescription: String? {
        description
    }
}

public enum ZoneStoredItemNameValidator {
    public static func validate(_ name: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              !name.contains("/"),
              name != ".",
              name != ".."
        else {
            throw ZoneLibraryError.invalidItemName(name)
        }
    }
}

private enum ZoneCaseOnlyRenameRollbackError: LocalizedError {
    case temporaryItemMissing(URL)
    case originalPathOccupied(URL)

    var errorDescription: String? {
        switch self {
        case let .temporaryItemMissing(url):
            return "Cannot restore case-only rename because the temporary item is missing: \(url.path)"
        case let .originalPathOccupied(url):
            return "Cannot restore case-only rename because the original path is occupied: \(url.path)"
        }
    }
}

public struct ZoneLibrary {
    public var rootURL: URL
    public var fileManager: FileManager
    private var contentsOfDirectory: (
        URL,
        [URLResourceKey]?,
        FileManager.DirectoryEnumerationOptions
    ) throws -> [URL]
    private var resourceValuesReader: (URL, Set<URLResourceKey>) throws -> ZoneFileResourceValues
    private var volumeSupportsCaseSensitiveNames: (URL) -> Bool?
    private var renameMoveItem: (URL, URL) throws -> Void

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.rootURL = rootURL ?? Self.defaultRootURL()
        self.fileManager = fileManager
        contentsOfDirectory = { url, keys, options in
            try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: options
            )
        }
        resourceValuesReader = { url, keys in
            ZoneFileResourceValues(try url.resourceValues(forKeys: keys))
        }
        volumeSupportsCaseSensitiveNames = { url in
            (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
                .volumeSupportsCaseSensitiveNames
        }
        renameMoveItem = { from, to in
            try fileManager.moveItem(at: from, to: to)
        }
    }

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        contentsOfDirectory: ((
            URL,
            [URLResourceKey]?,
            FileManager.DirectoryEnumerationOptions
        ) throws -> [URL])? = nil,
        resourceValuesReader: @escaping (URL, Set<URLResourceKey>) throws -> ZoneFileResourceValues = { url, keys in
            ZoneFileResourceValues(try url.resourceValues(forKeys: keys))
        },
        volumeSupportsCaseSensitiveNames: @escaping (URL) -> Bool? = { url in
            (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
                .volumeSupportsCaseSensitiveNames
        },
        renameMoveItem: ((URL, URL) throws -> Void)? = nil
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.contentsOfDirectory = contentsOfDirectory ?? { url, keys, options in
            try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: options
            )
        }
        self.resourceValuesReader = resourceValuesReader
        self.volumeSupportsCaseSensitiveNames = volumeSupportsCaseSensitiveNames
        self.renameMoveItem = renameMoveItem ?? { from, to in
            try fileManager.moveItem(at: from, to: to)
        }
    }

    public static func defaultRootURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZoneDesk Library", isDirectory: true)
    }

    public func directoryURL(for zone: ZoneModel) -> URL {
        rootURL.appendingPathComponent(safeDirectoryName(for: zone), isDirectory: true)
    }

    public func ensureDirectory(for zone: ZoneModel) throws -> URL {
        let directory = directoryURL(for: zone)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public func createDirectory(for zone: ZoneModel) throws -> URL {
        let directory = directoryURL(for: zone)
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw ZoneLibraryError.destinationDirectoryExists(directory)
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public func ensureDirectories(for zones: [ZoneModel]) throws {
        for zone in zones {
            _ = try ensureDirectory(for: zone)
        }
    }

    public func renameDirectory(from oldZone: ZoneModel, to newZone: ZoneModel) throws {
        let oldURL = directoryURL(for: oldZone)
        let newURL = directoryURL(for: newZone)
        guard oldURL != newURL else {
            _ = try ensureDirectory(for: newZone)
            return
        }

        guard fileManager.fileExists(atPath: oldURL.path) else {
            _ = try ensureDirectory(for: newZone)
            return
        }

        guard !fileManager.fileExists(atPath: newURL.path) else {
            throw ZoneLibraryError.destinationDirectoryExists(newURL)
        }

        try fileManager.moveItem(at: oldURL, to: newURL)
    }

    public func files(in zone: ZoneModel) throws -> [ZoneStoredFile] {
        let directory = try ensureDirectory(for: zone)
        let resourceKeys: Set<URLResourceKey> = [
            .isHiddenKey,
            .isDirectoryKey,
            .fileSizeKey,
            .contentAccessDateKey,
            .addedToDirectoryDateKey,
            .contentModificationDateKey,
            .creationDateKey,
            .tagNamesKey,
        ]
        let urls = try contentsOfDirectory(
            directory,
            Array(resourceKeys),
            [.skipsPackageDescendants]
        )

        return urls.compactMap { url in
            guard !url.lastPathComponent.hasPrefix(".") else {
                return nil
            }
            let resourceValues: ZoneFileResourceValues
            do {
                resourceValues = try resourceValuesReader(url, resourceKeys)
            } catch {
                guard fileManager.fileExists(atPath: url.path) else {
                    return nil
                }
                resourceValues = ZoneFileResourceValues()
            }
            guard resourceValues.isHidden != true else {
                return nil
            }

            return ZoneStoredFile(
                url: url,
                displayName: url.lastPathComponent,
                category: DesktopFileClassifier.classify(url: url),
                isDirectory: resourceValues.isDirectory ?? false,
                fileSize: resourceValues.fileSize,
                lastOpenedDate: resourceValues.lastOpenedDate,
                dateAdded: resourceValues.dateAdded,
                modificationDate: resourceValues.modificationDate,
                creationDate: resourceValues.creationDate,
                tagNames: resourceValues.tagNames ?? []
            )
        }
    }

    public func createFolder(in zone: ZoneModel, preferredName: String) throws -> URL {
        let directory = try ensureDirectory(for: zone)
        try ZoneStoredItemNameValidator.validate(preferredName)
        var index = 1

        while true {
            let candidateName = index == 1 ? preferredName : "\(preferredName) \(index)"
            let candidate = directory.appendingPathComponent(candidateName, isDirectory: true)
            if !fileManager.fileExists(atPath: candidate.path) {
                try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
                return candidate
            }
            index += 1
        }
    }

    public func renameStoredItem(
        at source: URL,
        to newName: String,
        in zone: ZoneModel
    ) throws -> URL {
        try ZoneStoredItemNameValidator.validate(newName)

        let directory = directoryURL(for: zone).standardizedFileURL
        let standardizedSource = source.standardizedFileURL
        guard standardizedSource.deletingLastPathComponent() == directory else {
            throw ZoneLibraryError.sourceOutsideZone(source)
        }

        let destination = directory.appendingPathComponent(newName)
        guard standardizedSource != destination.standardizedFileURL else {
            return standardizedSource
        }

        let isCaseOnlyRename = standardizedSource.lastPathComponent.compare(
            newName,
            options: [.caseInsensitive, .literal]
        ) == .orderedSame
        if isCaseOnlyRename,
           volumeSupportsCaseSensitiveNames(directory) != true {
            return try renameCaseOnlyStoredItem(
                from: standardizedSource,
                to: destination,
                in: directory
            )
        }

        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ZoneLibraryError.destinationItemExists(destination)
        }

        try renameMoveItem(standardizedSource, destination)
        return destination
    }

    public func duplicateStoredItem(at source: URL, in zone: ZoneModel) throws -> URL {
        let source = try validatedStoredItem(source, in: zone)
        var isDirectory: ObjCBool = false
        _ = fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory)
        let sourceIsDirectory = isDirectory.boolValue
        let destination = availableSiblingURL(
            in: source.deletingLastPathComponent(),
            stem: sourceIsDirectory ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent,
            pathExtension: sourceIsDirectory ? "" : source.pathExtension,
            firstSuffix: " 副本",
            isDirectory: sourceIsDirectory
        )

        try fileManager.copyItem(at: source, to: destination)
        return destination
    }

    public func archiveDestination(for source: URL, in zone: ZoneModel) throws -> URL {
        let source = try validatedStoredItem(source, in: zone)
        return availableSiblingURL(
            in: source.deletingLastPathComponent(),
            stem: source.lastPathComponent,
            pathExtension: "zip",
            firstSuffix: "",
            isDirectory: false
        )
    }

    public func aliasDestination(for source: URL, in zone: ZoneModel) throws -> URL {
        let source = try validatedStoredItem(source, in: zone)
        return availableSiblingURL(
            in: source.deletingLastPathComponent(),
            stem: source.lastPathComponent,
            pathExtension: "",
            firstSuffix: " 的替身",
            isDirectory: false
        )
    }

    public func collectDesktopFiles(from desktopURL: URL, zones: [ZoneModel]) -> ZoneCollectionReport {
        var moves: [ZoneCollectionMove] = []
        var failures: [ZoneCollectionFailure] = []
        let zoneByCategory = Dictionary(
            zones.flatMap { zone in zone.acceptedCategories.map { ($0, zone) } },
            uniquingKeysWith: { first, _ in first }
        )

        let desktopFiles: [URL]
        do {
            desktopFiles = try fileManager.contentsOfDirectory(
                at: desktopURL,
                includingPropertiesForKeys: [.isHiddenKey],
                options: [.skipsPackageDescendants]
            )
        } catch {
            return ZoneCollectionReport(
                failures: [ZoneCollectionFailure(source: desktopURL, message: String(describing: error))]
            )
        }

        for source in desktopFiles.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            guard !source.lastPathComponent.hasPrefix(".") else {
                continue
            }

            let category = DesktopFileClassifier.classify(url: source)
            guard let zone = zoneByCategory[category] else {
                continue
            }

            do {
                let directory = try ensureDirectory(for: zone)
                let destination = uniqueDestinationURL(
                    in: directory,
                    preferredName: source.lastPathComponent
                )
                try fileManager.moveItem(at: source, to: destination)
                moves.append(ZoneCollectionMove(source: source, destination: destination, zoneID: zone.id))
            } catch {
                failures.append(ZoneCollectionFailure(source: source, message: String(describing: error)))
            }
        }

        return ZoneCollectionReport(moves: moves, failures: failures)
    }

    public func restoreZoneToDesktop(
        _ zone: ZoneModel,
        desktopURL: URL
    ) -> ZoneRestoreReport {
        let directory = directoryURL(for: zone)
        guard fileManager.fileExists(atPath: directory.path) else {
            return ZoneRestoreReport()
        }

        let storedURLs: [URL]
        do {
            storedURLs = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsPackageDescendants]
            )
        } catch {
            return ZoneRestoreReport(
                failures: [
                    ZoneRestoreFailure(source: directory, message: String(describing: error)),
                ]
            )
        }

        var moves: [ZoneRestoreMove] = []
        var failures: [ZoneRestoreFailure] = []
        for source in storedURLs.sorted(by: {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }) {
            let destination = uniqueDestinationURL(
                in: desktopURL,
                preferredName: source.lastPathComponent
            )

            do {
                try fileManager.moveItem(at: source, to: destination)
                moves.append(ZoneRestoreMove(source: source, destination: destination))
            } catch {
                failures.append(
                    ZoneRestoreFailure(source: source, message: String(describing: error))
                )
            }
        }

        guard failures.isEmpty else {
            return ZoneRestoreReport(moves: moves, failures: failures)
        }

        do {
            let remainingURLs = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            guard remainingURLs.isEmpty else {
                return ZoneRestoreReport(
                    moves: moves,
                    failures: [
                        ZoneRestoreFailure(
                            source: directory,
                            message: "Zone directory is not empty after restoring its contents."
                        ),
                    ]
                )
            }
            try fileManager.removeItem(at: directory)
        } catch {
            failures.append(
                ZoneRestoreFailure(source: directory, message: String(describing: error))
            )
        }

        return ZoneRestoreReport(moves: moves, failures: failures)
    }

    private func safeDirectoryName(for zone: ZoneModel) -> String {
        let trimmed = zone.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = zone.id.uuidString
        let name = trimmed.isEmpty ? fallback : trimmed
        let invalidCharacters = CharacterSet(charactersIn: "/:")
        return name
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
    }

    private func validatedStoredItem(_ source: URL, in zone: ZoneModel) throws -> URL {
        let directory = directoryURL(for: zone).standardizedFileURL
        let standardizedSource = source.standardizedFileURL
        guard standardizedSource.deletingLastPathComponent() == directory else {
            throw ZoneLibraryError.sourceOutsideZone(source)
        }
        return standardizedSource
    }

    private func availableSiblingURL(
        in directory: URL,
        stem: String,
        pathExtension: String,
        firstSuffix: String,
        isDirectory: Bool
    ) -> URL {
        var index = 1

        while true {
            let suffix = index == 1 ? firstSuffix : "\(firstSuffix) \(index)"
            let candidateName = pathExtension.isEmpty
                ? "\(stem)\(suffix)"
                : "\(stem)\(suffix).\(pathExtension)"
            let candidate = directory.appendingPathComponent(
                candidateName,
                isDirectory: isDirectory
            )
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    private func renameCaseOnlyStoredItem(
        from source: URL,
        to destination: URL,
        in directory: URL
    ) throws -> URL {
        var temporaryURL: URL
        repeat {
            temporaryURL = directory.appendingPathComponent(
                ".ZoneDesk Rename \(UUID().uuidString)"
            )
        } while fileManager.fileExists(atPath: temporaryURL.path)

        try renameMoveItem(source, temporaryURL)
        do {
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw ZoneLibraryError.destinationItemExists(destination)
            }
            try renameMoveItem(temporaryURL, destination)
            return destination
        } catch let renameError {
            do {
                try restoreRenameItem(from: temporaryURL, to: source)
            } catch let rollbackError {
                throw ZoneLibraryError.caseOnlyRenameRollbackFailed(
                    original: source,
                    temporary: temporaryURL,
                    destination: destination,
                    renameFailure: renameError.localizedDescription,
                    rollbackFailure: rollbackError.localizedDescription
                )
            }
            throw renameError
        }
    }

    private func restoreRenameItem(from temporaryURL: URL, to source: URL) throws {
        guard fileManager.fileExists(atPath: temporaryURL.path) else {
            throw ZoneCaseOnlyRenameRollbackError.temporaryItemMissing(temporaryURL)
        }
        guard !fileManager.fileExists(atPath: source.path) else {
            throw ZoneCaseOnlyRenameRollbackError.originalPathOccupied(source)
        }
        try renameMoveItem(temporaryURL, source)
    }

    private func uniqueDestinationURL(in directory: URL, preferredName: String) -> URL {
        let preferredURL = directory.appendingPathComponent(preferredName)
        guard !fileManager.fileExists(atPath: preferredURL.path) else {
            let base = (preferredName as NSString).deletingPathExtension
            let ext = (preferredName as NSString).pathExtension

            var index = 2
            while true {
                let candidateName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
                let candidate = directory.appendingPathComponent(candidateName)
                if !fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
                index += 1
            }
        }

        return preferredURL
    }
}
