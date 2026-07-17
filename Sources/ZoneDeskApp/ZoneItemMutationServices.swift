import Darwin
import Foundation

protocol ZoneArchiveCreating {
    func createArchive(
        from source: URL,
        to destination: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    )
}

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

    private struct ReservationIdentity {
        let device: dev_t
        let inode: ino_t
    }

    init(launch: @escaping Launcher = DittoZoneArchiveCreator.launch) {
        self.launch = launch
    }

    func createArchive(
        from source: URL,
        to destination: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let reservation: ReservationIdentity
        do {
            reservation = try reserve(destination)
        } catch {
            completion(.failure(error))
            return
        }

        launch(
            URL(fileURLWithPath: "/usr/bin/ditto"),
            [
                "-c", "-k", "--sequesterRsrc", "--keepParent",
                source.path, destination.path,
            ],
            { result in
                if case .failure = result {
                    Self.removeReservation(at: destination, matching: reservation)
                }
                completion(result)
            }
        )
    }

    private func reserve(_ destination: URL) throws -> ReservationIdentity {
        let fileDescriptor: Int32 = destination.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            return Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL,
                S_IRUSR | S_IWUSR
            )
        }
        guard fileDescriptor >= 0 else {
            let errorCode = errno
            if errorCode == EEXIST {
                throw ZoneItemMutationError.destinationExists(destination)
            }
            throw ZoneItemMutationError.archiveFailed(
                String(cString: strerror(errorCode))
            )
        }
        defer { Darwin.close(fileDescriptor) }

        var metadata = stat()
        guard fstat(fileDescriptor, &metadata) == 0 else {
            let details = String(cString: strerror(errno))
            unlink(destination.path)
            throw ZoneItemMutationError.archiveFailed(details)
        }
        return ReservationIdentity(device: metadata.st_dev, inode: metadata.st_ino)
    }

    private static func removeReservation(
        at destination: URL,
        matching reservation: ReservationIdentity
    ) {
        var metadata = stat()
        let status: Int32 = destination.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &metadata)
        }
        guard status == 0,
              metadata.st_dev == reservation.device,
              metadata.st_ino == reservation.inode else {
            return
        }
        try? FileManager.default.removeItem(at: destination)
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

final class FinderZoneAliasCreator: ZoneAliasCreating {
    typealias ScriptExecutor = (String) -> NSDictionary?

    private let executeScript: ScriptExecutor

    init(executeScript: @escaping ScriptExecutor = FinderZoneAliasCreator.executeScript) {
        self.executeScript = executeScript
    }

    func createAlias(from source: URL, to destination: URL) throws {
        let sourceExpression = appleScriptStringExpression(source.path)
        let parentExpression = appleScriptStringExpression(
            destination.deletingLastPathComponent().path
        )
        let nameExpression = appleScriptStringExpression(destination.lastPathComponent)
        let script = """
        tell application "Finder"
            set destinationFolder to (POSIX file (\(parentExpression)) as alias)
            if exists item (\(nameExpression)) of destinationFolder then
                error "目标已存在，未覆盖。" number -48
            end if
            set sourceItem to (POSIX file (\(sourceExpression)) as alias)
            set createdAlias to make new alias file at destinationFolder to sourceItem
            set name of createdAlias to \(nameExpression)
        end tell
        """

        guard let errorInfo = executeScript(script) else {
            return
        }
        let details = (errorInfo[NSAppleScript.errorMessage] as? String)
            ?? "Finder 自动化请求被拒绝或执行失败。"
        throw ZoneItemMutationError.aliasFailed(details)
    }

    private func appleScriptStringExpression(_ value: String) -> String {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                ZoneFileContextMenuController.appleScriptStringExpression(value)
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                ZoneFileContextMenuController.appleScriptStringExpression(value)
            }
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
