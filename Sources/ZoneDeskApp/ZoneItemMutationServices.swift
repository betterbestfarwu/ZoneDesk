import Darwin
import Foundation

protocol ZoneArchiveCreating {
    func createArchive(
        from source: URL,
        to destination: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    )
}

@MainActor
protocol ZoneAliasCreating {
    func createAlias(from source: URL, to destination: URL) throws
}

enum ZoneItemMutationError: LocalizedError {
    case archiveFailed(String)
    case aliasFailed(String)
    case destinationExists(URL)

    var errorDescription: String? {
        switch self {
        case let .archiveFailed(details):
            return details.isEmpty ? "无法创建归档。" : "无法创建归档：\(details)"
        case let .aliasFailed(details):
            return details.isEmpty ? "无法创建替身。" : "无法创建替身：\(details)"
        case let .destinationExists(destination):
            return "目标已存在，未覆盖：\(destination.lastPathComponent)"
        }
    }
}

final class DittoZoneArchiveCreator: ZoneArchiveCreating {
    typealias Launcher = (
        URL,
        [String],
        @escaping (Result<Void, Error>) -> Void
    ) -> Void

    private let launch: Launcher

    init(launch: @escaping Launcher = DittoZoneArchiveCreator.launch) {
        self.launch = launch
    }

    func createArchive(
        from source: URL,
        to destination: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let stagingDirectory: URL
        do {
            stagingDirectory = try ZoneMutationStaging.createDirectory(
                in: destination.deletingLastPathComponent()
            )
        } catch {
            completion(.failure(ZoneItemMutationError.archiveFailed(error.localizedDescription)))
            return
        }

        let stagedArchive = stagingDirectory.appendingPathComponent(
            destination.lastPathComponent
        )
        let completionGate = ZoneMutationCompletionGate()
        launch(
            URL(fileURLWithPath: "/usr/bin/ditto"),
            [
                "-c", "-k", "--sequesterRsrc", "--keepParent",
                source.path, stagedArchive.path,
            ],
            { result in
                guard completionGate.claim() else { return }
                defer {
                    ZoneMutationStaging.removeDirectory(stagingDirectory)
                }

                switch result {
                case let .failure(error):
                    completion(.failure(error))
                case .success:
                    do {
                        try ZoneMutationStaging.publishNoReplace(
                            stagedArchive,
                            to: destination
                        )
                        completion(.success(()))
                    } catch let error as ZoneItemMutationError {
                        completion(.failure(error))
                    } catch {
                        completion(.failure(ZoneItemMutationError.archiveFailed(
                            error.localizedDescription
                        )))
                    }
                }
            }
        )
    }

    private static func launch(
        executable: URL,
        arguments: [String],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let standardError = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardError = standardError

            do {
                try process.run()
                let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    let details = String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    completion(.failure(ZoneItemMutationError.archiveFailed(details)))
                    return
                }
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

@MainActor
final class FinderZoneAliasCreator: ZoneAliasCreating {
    typealias ScriptExecutor = @MainActor (String) -> NSDictionary?

    private let executeScript: ScriptExecutor

    init(executeScript: @escaping ScriptExecutor = FinderZoneAliasCreator.executeScript) {
        self.executeScript = executeScript
    }

    func createAlias(from source: URL, to destination: URL) throws {
        let stagingDirectory: URL
        do {
            stagingDirectory = try ZoneMutationStaging.createDirectory(
                in: destination.deletingLastPathComponent()
            )
        } catch {
            throw ZoneItemMutationError.aliasFailed(error.localizedDescription)
        }
        defer {
            ZoneMutationStaging.removeDirectory(stagingDirectory)
        }

        let stagedAlias = stagingDirectory.appendingPathComponent(
            destination.lastPathComponent
        )
        let sourceExpression = ZoneFileContextMenuController.appleScriptStringExpression(
            source.path
        )
        let stagingExpression = ZoneFileContextMenuController.appleScriptStringExpression(
            stagingDirectory.path
        )
        let nameExpression = ZoneFileContextMenuController.appleScriptStringExpression(
            stagedAlias.lastPathComponent
        )
        let script = """
        tell application "Finder"
            set destinationFolder to (POSIX file (\(stagingExpression)) as alias)
            set sourceItem to (POSIX file (\(sourceExpression)) as alias)
            set createdAlias to make new alias file at destinationFolder to sourceItem
            set name of createdAlias to \(nameExpression)
        end tell
        """

        if let errorInfo = executeScript(script) {
            let details = (errorInfo[NSAppleScript.errorMessage] as? String)
                ?? "Finder 自动化请求被拒绝或执行失败。"
            throw ZoneItemMutationError.aliasFailed(details)
        }

        do {
            try ZoneMutationStaging.publishNoReplace(stagedAlias, to: destination)
        } catch let error as ZoneItemMutationError {
            throw error
        } catch {
            throw ZoneItemMutationError.aliasFailed(error.localizedDescription)
        }
    }

    private static func executeScript(_ source: String) -> NSDictionary? {
        guard let script = NSAppleScript(source: source) else {
            return [NSAppleScript.errorMessage: "无法创建 Finder 自动化请求。"]
        }
        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        return errorInfo
    }
}

private enum ZoneMutationStaging {
    static func createDirectory(in parent: URL) throws -> URL {
        let templatePath = parent.appendingPathComponent(
            ".zonedesk-mutation-XXXXXX",
            isDirectory: true
        ).path
        var template = templatePath.utf8CString
        let directory = template.withUnsafeMutableBufferPointer { buffer -> URL? in
            guard let baseAddress = buffer.baseAddress,
                  let createdPath = Darwin.mkdtemp(baseAddress) else {
                return nil
            }
            return URL(
                fileURLWithFileSystemRepresentation: createdPath,
                isDirectory: true,
                relativeTo: nil
            )
        }
        guard let directory else {
            throw ZoneMutationStagingError.posix(errno)
        }
        return directory
    }

    static func publishNoReplace(_ source: URL, to destination: URL) throws {
        let status: Int32 = source.withUnsafeFileSystemRepresentation { sourcePath in
            guard let sourcePath else {
                errno = EINVAL
                return Int32(-1)
            }
            return destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let destinationPath else {
                    errno = EINVAL
                    return Int32(-1)
                }
                return Darwin.renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard status == 0 else {
            let errorCode = errno
            if errorCode == EEXIST {
                throw ZoneItemMutationError.destinationExists(destination)
            }
            throw ZoneMutationStagingError.posix(errorCode)
        }
    }

    static func removeDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum ZoneMutationStagingError: LocalizedError {
    case posix(Int32)

    var errorDescription: String? {
        switch self {
        case let .posix(errorCode):
            return String(cString: strerror(errorCode))
        }
    }
}

private final class ZoneMutationCompletionGate {
    private let lock = NSLock()
    private var isClaimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }
}
