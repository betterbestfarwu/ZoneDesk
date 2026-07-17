import Foundation
import Testing
@testable import ZoneDeskApp

@Suite("Zone item mutation services")
struct ZoneItemMutationServicesTests {
    @Test("archive creator launches ditto with the expected arguments")
    func archiveCreatorLaunchesDitto() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = URL(fileURLWithPath: "/tmp/source folder")
        let destination = directory.appendingPathComponent("archive.zip")
        var capturedExecutable: URL?
        var capturedArguments: [String] = []
        var archiveResult: Result<Void, Error>?
        let creator = DittoZoneArchiveCreator { executable, arguments, completion in
            capturedExecutable = executable
            capturedArguments = arguments
            completion(.success(()))
        }

        creator.createArchive(from: source, to: destination) { archiveResult = $0 }

        #expect(capturedExecutable?.path == "/usr/bin/ditto")
        #expect(capturedArguments == [
            "-c", "-k", "--sequesterRsrc", "--keepParent",
            source.path, destination.path,
        ])
        guard case .success? = archiveResult else {
            Issue.record("archive completion should succeed")
            return
        }
    }

    @Test("archive creator preserves launch failures")
    func archiveCreatorPreservesLaunchFailure() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
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

    @Test("archive creator refuses an occupied destination without launching ditto")
    func archiveCreatorRefusesOccupiedDestination() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let destination = directory.appendingPathComponent("archive.zip")
        try Data("existing archive".utf8).write(to: destination)
        var didLaunch = false
        var archiveResult: Result<Void, Error>?
        let creator = DittoZoneArchiveCreator { _, _, completion in
            didLaunch = true
            completion(.success(()))
        }

        creator.createArchive(from: source, to: destination) { archiveResult = $0 }

        #expect(!didLaunch)
        guard case .failure? = archiveResult else {
            Issue.record("an occupied destination should fail")
            return
        }
        #expect(try Data(contentsOf: destination) == Data("existing archive".utf8))
    }

    @Test("archive creator removes its reservation after a launch failure")
    func archiveCreatorCleansUpFailedReservation() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let destination = directory.appendingPathComponent("archive.zip")
        var destinationWasReserved = false
        let creator = DittoZoneArchiveCreator { _, _, completion in
            destinationWasReserved = FileManager.default.fileExists(atPath: destination.path)
            try? Data("partial archive".utf8).write(to: destination)
            completion(.failure(MutationServiceTestError.archiveFailed))
        }

        creator.createArchive(from: source, to: destination) { _ in }

        #expect(destinationWasReserved)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("alias creator asks Finder to create an alias")
    func aliasCreatorUsesFinder() throws {
        let item = URL(fileURLWithPath: "/tmp/source item")
        let alias = URL(fileURLWithPath: "/tmp/source item alias")
        var capturedScript: String?
        let aliasCreator = FinderZoneAliasCreator { scriptSource in
            capturedScript = scriptSource
            return nil
        }

        try aliasCreator.createAlias(from: item, to: alias)

        #expect(capturedScript?.contains("tell application \"Finder\"") == true)
        #expect(capturedScript?.contains("make new alias file") == true)
        let occupiedCheck = capturedScript?.range(of: "if exists item")
        let aliasCreation = capturedScript?.range(of: "make new alias file")
        #expect(occupiedCheck != nil)
        #expect(aliasCreation != nil)
        if let occupiedCheck, let aliasCreation {
            #expect(occupiedCheck.lowerBound < aliasCreation.lowerBound)
        }
    }

    @Test("alias creator reports Finder automation errors")
    func aliasCreatorReportsFinderErrors() {
        let item = URL(fileURLWithPath: "/tmp/source")
        let alias = URL(fileURLWithPath: "/tmp/source alias")
        let deniedAliasCreator = FinderZoneAliasCreator { _ in
            [NSAppleScript.errorMessage: "automation denied"] as NSDictionary
        }

        #expect(throws: ZoneItemMutationError.self) {
            try deniedAliasCreator.createAlias(from: item, to: alias)
        }
    }
}

private enum MutationServiceTestError: LocalizedError {
    case archiveFailed

    var errorDescription: String? { "archive failed" }
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
