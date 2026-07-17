import AppKit
import Testing
@testable import ZoneDeskApp
import ZoneDeskCore

@Suite("Zone file thumbnails")
@MainActor
struct ZoneFileThumbnailProviderTests {
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

    @Test("decodes an image thumbnail within the requested bounds")
    func decodesImage() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoneThumb-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = NSImage(size: NSSize(width: 160, height: 80))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 160, height: 80).fill()
        image.unlockFocus()
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
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
}
