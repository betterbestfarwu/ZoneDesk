import Foundation
import Testing
@testable import ZoneDeskApp

@MainActor
@Suite("Zone item mutation services")
struct ZoneItemMutationServicesTests {
    @Test("archive creator launches ditto with the expected arguments")
    func archiveCreatorLaunchesDitto() throws {
        let library = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let directory = try makeZoneDirectory(in: library)
        let source = URL(fileURLWithPath: "/tmp/source folder")
        let destination = directory.appendingPathComponent("archive.zip")
        var capturedExecutable: URL?
        var capturedArguments: [String] = []
        var generatedArchive: URL?
        var privateDirectoryPermissions: NSNumber?
        var archiveResult: Result<Void, Error>?
        let creator = DittoZoneArchiveCreator { executable, arguments, completion in
            capturedExecutable = executable
            capturedArguments = arguments
            guard let outputPath = arguments.last else {
                completion(.failure(MutationServiceTestError.missingOutput))
                return
            }
            let output = URL(fileURLWithPath: outputPath)
            generatedArchive = output
            privateDirectoryPermissions = try? FileManager.default.attributesOfItem(
                atPath: output.deletingLastPathComponent().path
            )[.posixPermissions] as? NSNumber
            do {
                try Data("generated archive".utf8).write(to: output)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }

        creator.createArchive(from: source, to: destination) { archiveResult = $0 }

        #expect(capturedExecutable?.path == "/usr/bin/ditto")
        #expect(capturedArguments.dropLast() == [
            "-c", "-k", "--sequesterRsrc", "--keepParent",
            source.path,
        ])
        #expect(generatedArchive?.deletingLastPathComponent().deletingLastPathComponent() == library)
        #expect(generatedArchive?.deletingLastPathComponent().lastPathComponent.hasPrefix(".zonedesk-mutation-") == true)
        #expect(privateDirectoryPermissions?.intValue == 0o700)
        #expect(try Data(contentsOf: destination) == Data("generated archive".utf8))
        #expect(try temporaryMutationDirectories(in: library).isEmpty)
        guard case .success? = archiveResult else {
            Issue.record("archive completion should succeed")
            return
        }
    }

    @Test("archive creator preserves launch failures")
    func archiveCreatorPreservesLaunchFailure() throws {
        let library = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let directory = try makeZoneDirectory(in: library)
        let source = URL(fileURLWithPath: "/tmp/source")
        let destination = directory.appendingPathComponent("archive.zip")
        var archiveFailure: Result<Void, Error>?
        let failingCreator = DittoZoneArchiveCreator { _, _, completion in
            completion(.failure(MutationServiceTestError.archiveFailed))
        }

        failingCreator.createArchive(from: source, to: destination) { archiveFailure = $0 }

        guard case let .failure(error)? = archiveFailure else {
            Issue.record("archive completion should preserve the launch failure")
            return
        }
        #expect(error.localizedDescription == "archive failed")
    }

    @Test("archive creator refuses an occupied destination without replacing it")
    func archiveCreatorRefusesOccupiedDestination() throws {
        let library = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let directory = try makeZoneDirectory(in: library)
        let source = directory.appendingPathComponent("source")
        let destination = directory.appendingPathComponent("archive.zip")
        try Data("existing archive".utf8).write(to: destination)
        var archiveResult: Result<Void, Error>?
        let creator = DittoZoneArchiveCreator { _, arguments, completion in
            do {
                try Data("generated archive".utf8).write(
                    to: URL(fileURLWithPath: try #require(arguments.last))
                )
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }

        creator.createArchive(from: source, to: destination) { archiveResult = $0 }

        guard case .failure? = archiveResult else {
            Issue.record("an occupied destination should fail")
            return
        }
        #expect(try Data(contentsOf: destination) == Data("existing archive".utf8))
        #expect(try temporaryMutationDirectories(in: library).isEmpty)
    }

    @Test("archive creator removes its private output after a launch failure")
    func archiveCreatorCleansUpFailedPrivateOutput() throws {
        let library = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let directory = try makeZoneDirectory(in: library)
        let source = directory.appendingPathComponent("source")
        let destination = directory.appendingPathComponent("archive.zip")
        var generatedArchive: URL?
        let creator = DittoZoneArchiveCreator { _, arguments, completion in
            generatedArchive = arguments.last.map(URL.init(fileURLWithPath:))
            if let generatedArchive {
                try? Data("partial archive".utf8).write(to: generatedArchive)
            }
            completion(.failure(MutationServiceTestError.archiveFailed))
        }

        creator.createArchive(from: source, to: destination) { _ in }

        #expect(generatedArchive?.deletingLastPathComponent().lastPathComponent.hasPrefix(".zonedesk-mutation-") == true)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try temporaryMutationDirectories(in: library).isEmpty)
    }

    @Test("archive publication fails and cleans stable staging after the zone moves")
    func archivePublicationFailsAfterZoneMoves() throws {
        let library = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let directory = try makeZoneDirectory(in: library)
        let movedDirectory = library.appendingPathComponent("Moved Zone", isDirectory: true)

        try assertArchivePublicationFailsAfterZoneMutation(
            library: library,
            directory: directory
        ) {
            try FileManager.default.moveItem(at: directory, to: movedDirectory)
        }

        #expect(try temporaryMutationDirectories(in: movedDirectory).isEmpty)
    }

    @Test("archive publication fails and cleans stable staging after the zone is deleted")
    func archivePublicationFailsAfterZoneDeletion() throws {
        let library = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let directory = try makeZoneDirectory(in: library)

        try assertArchivePublicationFailsAfterZoneMutation(
            library: library,
            directory: directory
        ) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    @Test("archive creator accepts only the first launcher completion")
    func archiveCreatorCompletesOnceWithFirstResult() throws {
        let library = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let directory = try makeZoneDirectory(in: library)
        let source = directory.appendingPathComponent("source")
        let destination = directory.appendingPathComponent("archive.zip")
        var completionCount = 0
        var archiveResult: Result<Void, Error>?
        let creator = DittoZoneArchiveCreator { _, arguments, completion in
            do {
                try Data("generated archive".utf8).write(
                    to: URL(fileURLWithPath: try #require(arguments.last))
                )
                completion(.success(()))
                completion(.failure(MutationServiceTestError.archiveFailed))
            } catch {
                completion(.failure(error))
            }
        }

        creator.createArchive(from: source, to: destination) { result in
            completionCount += 1
            archiveResult = result
        }

        #expect(completionCount == 1)
        guard case .success? = archiveResult else {
            Issue.record("archive completion should preserve the first successful result")
            return
        }
        #expect(try Data(contentsOf: destination) == Data("generated archive".utf8))
        #expect(try temporaryMutationDirectories(in: library).isEmpty)
    }

    @Test("archive publication collision preserves the winner and completes once")
    func archivePublicationCollisionIsNoReplace() throws {
        let library = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let directory = try makeZoneDirectory(in: library)
        let source = directory.appendingPathComponent("source")
        let destination = directory.appendingPathComponent("archive.zip")
        var completionCount = 0
        var archiveResult: Result<Void, Error>?
        let creator = DittoZoneArchiveCreator { _, arguments, completion in
            do {
                let generatedArchive = URL(fileURLWithPath: try #require(arguments.last))
                try Data("generated archive".utf8).write(to: generatedArchive)
                try Data("race winner".utf8).write(to: destination)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }

        creator.createArchive(from: source, to: destination) { result in
            completionCount += 1
            archiveResult = result
        }

        #expect(completionCount == 1)
        guard case let .failure(error)? = archiveResult else {
            Issue.record("a publication collision should fail")
            return
        }
        #expect(error is ZoneItemMutationError)
        #expect(try Data(contentsOf: destination) == Data("race winner".utf8))
        #expect(try temporaryMutationDirectories(in: library).isEmpty)
    }

    @Test("alias creator asks Finder to create an alias")
    func aliasCreatorUsesFinder() throws {
        let library = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let directory = library.appendingPathComponent("target \\\"folder\nline", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let item = URL(fileURLWithPath: "/tmp/source \\\"item\nline")
        let alias = directory.appendingPathComponent("source \\\"item alias\nline")
        var capturedScript: String?
        var privateDirectory: URL?
        let aliasCreator = FinderZoneAliasCreator { scriptSource in
            capturedScript = scriptSource
            let privateDirectories = try? temporaryMutationDirectories(in: library)
            privateDirectory = privateDirectories?.only
            if let privateDirectory {
                try? Data("alias".utf8).write(
                    to: privateDirectory.appendingPathComponent(alias.lastPathComponent)
                )
            }
            return nil
        }

        try aliasCreator.createAlias(from: item, to: alias)

        #expect(capturedScript?.contains("tell application \"Finder\"") == true)
        #expect(capturedScript?.contains("make new alias file") == true)
        if let privateDirectory {
            let scriptDirectory = library.appendingPathComponent(
                privateDirectory.lastPathComponent,
                isDirectory: true
            )
            let directoryExpression = ZoneFileContextMenuController.appleScriptStringExpression(
                scriptDirectory.path
            )
            let nameExpression = ZoneFileContextMenuController.appleScriptStringExpression(
                alias.lastPathComponent
            )
            #expect(capturedScript?.contains("POSIX file (\(directoryExpression))") == true)
            #expect(capturedScript?.contains("set name of createdAlias to \(nameExpression)") == true)
        }
        #expect(FileManager.default.fileExists(atPath: alias.path))
        #expect(try temporaryMutationDirectories(in: library).isEmpty)
    }

    @Test("alias creator reports Finder automation errors")
    func aliasCreatorReportsFinderErrors() {
        let library: URL
        let directory: URL
        do {
            library = try makeTemporaryDirectory()
            directory = try makeZoneDirectory(in: library)
        } catch {
            Issue.record(error)
            return
        }
        defer { try? FileManager.default.removeItem(at: library) }
        let item = directory.appendingPathComponent("source")
        let alias = directory.appendingPathComponent("source alias")
        var didCreatePrivateDirectory = false
        let deniedAliasCreator = FinderZoneAliasCreator { _ in
            didCreatePrivateDirectory = (try? temporaryMutationDirectories(in: library).count) == 1
            return [NSAppleScript.errorMessage: "automation denied"] as NSDictionary
        }

        #expect(throws: ZoneItemMutationError.self) {
            try deniedAliasCreator.createAlias(from: item, to: alias)
        }
        #expect(didCreatePrivateDirectory)
        #expect(!FileManager.default.fileExists(atPath: alias.path))
        #expect((try? temporaryMutationDirectories(in: library).isEmpty) == true)
    }

    @Test("alias publication collision preserves the winner and cleans private output")
    func aliasPublicationCollisionIsNoReplace() throws {
        let library = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let directory = try makeZoneDirectory(in: library)
        let item = directory.appendingPathComponent("source")
        let alias = directory.appendingPathComponent("source alias")
        let aliasCreator = FinderZoneAliasCreator { _ in
            do {
                let privateDirectory = try #require(
                    temporaryMutationDirectories(in: library).only
                )
                try Data("generated alias".utf8).write(
                    to: privateDirectory.appendingPathComponent(alias.lastPathComponent)
                )
                try Data("race winner".utf8).write(to: alias)
                return nil
            } catch {
                return [NSAppleScript.errorMessage: error.localizedDescription] as NSDictionary
            }
        }

        #expect(throws: ZoneItemMutationError.self) {
            try aliasCreator.createAlias(from: item, to: alias)
        }
        #expect(try Data(contentsOf: alias) == Data("race winner".utf8))
        #expect(try temporaryMutationDirectories(in: library).isEmpty)
    }
}

private func assertArchivePublicationFailsAfterZoneMutation(
    library: URL,
    directory: URL,
    mutateZone: () throws -> Void
) throws {
    let source = directory.appendingPathComponent("source")
    let destination = directory.appendingPathComponent("archive.zip")
    var launchCompletion: ((Result<Void, Error>) -> Void)?
    var archiveResult: Result<Void, Error>?
    let creator = DittoZoneArchiveCreator { _, arguments, completion in
        guard let outputPath = arguments.last else {
            completion(.failure(MutationServiceTestError.missingOutput))
            return
        }
        do {
            try Data("generated archive".utf8).write(
                to: URL(fileURLWithPath: outputPath)
            )
            launchCompletion = completion
        } catch {
            completion(.failure(error))
        }
    }

    creator.createArchive(from: source, to: destination) { archiveResult = $0 }
    #expect(try temporaryMutationDirectories(in: library).count == 1)
    try mutateZone()
    launchCompletion?(.success(()))

    guard case .failure? = archiveResult else {
        Issue.record("publishing to a moved or deleted zone should fail")
        return
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(try temporaryMutationDirectories(in: library).isEmpty)
}

private enum MutationServiceTestError: LocalizedError {
    case archiveFailed
    case missingOutput

    var errorDescription: String? {
        switch self {
        case .archiveFailed: "archive failed"
        case .missingOutput: "missing output"
        }
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    return directory
}

private func makeZoneDirectory(in library: URL) throws -> URL {
    let directory = library.appendingPathComponent("Zone", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    return directory
}

private func temporaryMutationDirectories(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter {
        $0.lastPathComponent.hasPrefix(".zonedesk-mutation-")
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
