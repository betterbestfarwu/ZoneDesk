import AppKit
import AVFoundation
import Testing
@testable import ZoneDeskApp
import ZoneDeskCore

private final class LockedDecodeState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var ranOnMainThread = true

    func recordDecode() {
        lock.lock()
        count += 1
        ranOnMainThread = Thread.isMainThread
        lock.unlock()
    }

    func snapshot() -> (count: Int, ranOnMainThread: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (count, ranOnMainThread)
    }
}

@Suite("Zone file thumbnails")
@MainActor
struct ZoneFileThumbnailProviderTests {
    @Test("video generator requests the exact time-zero frame")
    func videoGeneratorUsesExactTimeZero() {
        let generator = AVAssetImageGenerator(asset: AVMutableComposition())
        let maximumSize = NSSize(width: 120, height: 80)

        ZoneFileThumbnailProvider.configureVideoGenerator(
            generator,
            maximumSize: maximumSize
        )

        #expect(generator.requestedTimeToleranceBefore == .zero)
        #expect(generator.requestedTimeToleranceAfter == .zero)
        #expect(generator.appliesPreferredTrackTransform)
        #expect(generator.maximumSize == maximumSize)
    }

    @Test("cache key changes with modification date and size")
    func cacheKeyIdentity() {
        let url = URL(fileURLWithPath: "/tmp/image.png")
        let first = ZoneFileThumbnailCacheKey(
            url: url,
            modificationDate: Date(timeIntervalSince1970: 1),
            pixelSize: 64
        )
        let changedDate = ZoneFileThumbnailCacheKey(
            url: url,
            modificationDate: Date(timeIntervalSince1970: 2),
            pixelSize: 64
        )
        let changedSize = ZoneFileThumbnailCacheKey(
            url: url,
            modificationDate: Date(timeIntervalSince1970: 1),
            pixelSize: 128
        )

        #expect(first != changedDate)
        #expect(first != changedSize)
    }

    @Test("cache key distinguishes rectangular pixel sizes")
    func rectangularCacheKeyIdentity() {
        let url = URL(fileURLWithPath: "/tmp/image.png")
        let landscape = ZoneFileThumbnailCacheKey(
            url: url,
            modificationDate: nil,
            pixelWidth: 200,
            pixelHeight: 100
        )
        let portrait = ZoneFileThumbnailCacheKey(
            url: url,
            modificationDate: nil,
            pixelWidth: 100,
            pixelHeight: 200
        )

        #expect(landscape != portrait)
    }

    @Test("decodes an image thumbnail within the requested bounds")
    func decodesImage() async throws {
        let url = try makeTemporaryPNG(size: NSSize(width: 160, height: 80))
        defer { try? FileManager.default.removeItem(at: url) }
        let file = ZoneStoredFile(
            url: url,
            displayName: url.lastPathComponent,
            category: .image
        )
        let provider = ZoneFileThumbnailProvider()

        let thumbnail = await withCheckedContinuation { continuation in
            provider.thumbnail(for: file, size: NSSize(width: 64, height: 64)) {
                continuation.resume(returning: $0)
            }
        }

        #expect(thumbnail != nil)
        #expect((thumbnail?.size.width ?? 0) <= 64)
        #expect((thumbnail?.size.height ?? 0) <= 64)
    }

    @Test("aspect-fits a landscape image within portrait bounds")
    func aspectFitsImageWithinRectangularBounds() async throws {
        let url = try makeTemporaryPNG(size: NSSize(width: 200, height: 100))
        defer { try? FileManager.default.removeItem(at: url) }
        let file = ZoneStoredFile(
            url: url,
            displayName: url.lastPathComponent,
            category: .image
        )
        let provider = ZoneFileThumbnailProvider()

        let (thumbnail, _) = await requestThumbnail(
            from: provider,
            for: file,
            size: NSSize(width: 100, height: 200)
        )

        #expect(thumbnail != nil)
        #expect((thumbnail?.size.width ?? 0) <= 100)
        #expect((thumbnail?.size.height ?? 0) <= 200)
    }

    @Test("rejects directories and non-media files synchronously")
    func rejectsUnsupportedFilesSynchronously() {
        let provider = ZoneFileThumbnailProvider()
        let files = [
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/folder"),
                displayName: "folder",
                category: .image,
                isDirectory: true
            ),
            ZoneStoredFile(
                url: URL(fileURLWithPath: "/tmp/document.txt"),
                displayName: "document.txt",
                category: .document
            ),
        ]

        for file in files {
            var completionCount = 0
            var receivedImage = false
            provider.thumbnail(for: file, size: NSSize(width: 64, height: 64)) { image in
                completionCount += 1
                receivedImage = image != nil
                #expect(Thread.isMainThread)
            }

            #expect(completionCount == 1)
            #expect(!receivedImage)
        }
    }

    @Test("rejects invalid and unrepresentable sizes synchronously")
    func rejectsInvalidSizesSynchronously() {
        let provider = ZoneFileThumbnailProvider()
        let file = ZoneStoredFile(
            url: URL(fileURLWithPath: "/tmp/image.png"),
            displayName: "image.png",
            category: .image
        )
        let sizes = [
            NSSize(width: 0, height: 64),
            NSSize(width: -1, height: 64),
            NSSize(width: CGFloat.nan, height: 64),
            NSSize(width: CGFloat.infinity, height: 64),
            NSSize(width: CGFloat.greatestFiniteMagnitude, height: 64),
        ]

        for size in sizes {
            var completionCount = 0
            var receivedImage = false
            provider.thumbnail(for: file, size: size) { image in
                completionCount += 1
                receivedImage = image != nil
                #expect(Thread.isMainThread)
            }

            #expect(completionCount == 1)
            #expect(!receivedImage)
        }
    }

    @Test("returns nil on decode failure")
    func decodeFailureReturnsNil() async {
        let file = ZoneStoredFile(
            url: URL(fileURLWithPath: "/tmp/ZoneThumb-missing-\(UUID()).png"),
            displayName: "missing.png",
            category: .image
        )
        let provider = ZoneFileThumbnailProvider()

        let (thumbnail, completedOnMainThread) = await requestThumbnail(
            from: provider,
            for: file,
            size: NSSize(width: 64, height: 64)
        )

        #expect(thumbnail == nil)
        #expect(completedOnMainThread)
    }

    @Test("deduplicates matching requests and completes each once on the main thread")
    func deduplicatesMatchingRequests() async {
        let decodeStarted = DispatchSemaphore(value: 0)
        let allowDecodeToFinish = DispatchSemaphore(value: 0)
        let decodeState = LockedDecodeState()
        let provider = ZoneFileThumbnailProvider(decoder: { _, _ in
            decodeState.recordDecode()
            decodeStarted.signal()
            allowDecodeToFinish.wait()
            return nil
        })
        let file = ZoneStoredFile(
            url: URL(fileURLWithPath: "/tmp/image.png"),
            displayName: "image.png",
            category: .image,
            modificationDate: Date(timeIntervalSince1970: 1)
        )
        let completionsFinished = DispatchSemaphore(value: 0)
        var completionCount = 0
        var allCompletionsOnMainThread = true
        let completion: (NSImage?) -> Void = { image in
            #expect(image == nil)
            completionCount += 1
            allCompletionsOnMainThread = allCompletionsOnMainThread && Thread.isMainThread
            completionsFinished.signal()
        }

        provider.thumbnail(
            for: file,
            size: NSSize(width: 100, height: 200),
            completion: completion
        )
        await wait(for: decodeStarted)
        provider.thumbnail(
            for: file,
            size: NSSize(width: 100, height: 200),
            completion: completion
        )
        allowDecodeToFinish.signal()
        await wait(for: completionsFinished)
        await wait(for: completionsFinished)
        await Task.yield()

        let decodeSnapshot = decodeState.snapshot()
        #expect(decodeSnapshot.count == 1)
        #expect(!decodeSnapshot.ranOnMainThread)
        #expect(completionCount == 2)
        #expect(allCompletionsOnMainThread)
    }

    private func makeTemporaryPNG(size: NSSize) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoneThumb-\(UUID()).png")
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    private func requestThumbnail(
        from provider: ZoneFileThumbnailProvider,
        for file: ZoneStoredFile,
        size: NSSize
    ) async -> (NSImage?, Bool) {
        await withCheckedContinuation { continuation in
            provider.thumbnail(for: file, size: size) { image in
                continuation.resume(returning: (image, Thread.isMainThread))
            }
        }
    }

    private func wait(for semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                semaphore.wait()
                continuation.resume()
            }
        }
    }
}
