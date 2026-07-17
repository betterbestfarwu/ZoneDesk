import AppKit
import AVFoundation
import ImageIO
import ZoneDeskCore

private typealias ZoneFileThumbnailCompletion = (NSImage?) -> Void

private final class ZoneFileThumbnailState: @unchecked Sendable {
    var inFlight: [ZoneFileThumbnailCacheKey: [ZoneFileThumbnailCompletion]] = [:]
}

@MainActor
protocol ZoneFileThumbnailProviding: AnyObject {
    func thumbnail(
        for file: ZoneStoredFile,
        size: NSSize,
        completion: @escaping (NSImage?) -> Void
    )
}

struct ZoneFileThumbnailCacheKey: Hashable {
    let url: URL
    let modificationDate: Date?
    let pixelSize: Int

    init(url: URL, modificationDate: Date?, pixelSize: Int) {
        self.url = url.standardizedFileURL
        self.modificationDate = modificationDate
        self.pixelSize = pixelSize
    }
}

@MainActor
final class ZoneFileThumbnailProvider: ZoneFileThumbnailProviding {
    private final class WrappedKey: NSObject {
        let value: ZoneFileThumbnailCacheKey

        init(_ value: ZoneFileThumbnailCacheKey) {
            self.value = value
        }

        override var hash: Int {
            value.hashValue
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? WrappedKey else {
                return false
            }
            return value == other.value
        }
    }

    private let cache = NSCache<WrappedKey, NSImage>()
    private let stateQueue = DispatchQueue(label: "ZoneDesk.thumbnail-state")
    private let workerQueue = DispatchQueue(
        label: "ZoneDesk.thumbnail-worker",
        qos: .utility
    )
    private let state = ZoneFileThumbnailState()

    func thumbnail(
        for file: ZoneStoredFile,
        size: NSSize,
        completion: @escaping (NSImage?) -> Void
    ) {
        guard !file.isDirectory,
              Self.supportedCategories.contains(file.category),
              size.width > 0,
              size.height > 0 else {
            completion(nil)
            return
        }

        let pixelSize = Int(ceil(max(size.width, size.height)))
        let key = ZoneFileThumbnailCacheKey(
            url: file.url,
            modificationDate: file.modificationDate,
            pixelSize: pixelSize
        )
        if let image = cache.object(forKey: WrappedKey(key)) {
            completion(image)
            return
        }

        let state = state
        let stateQueue = stateQueue
        let workerQueue = workerQueue
        stateQueue.async { [self] in
            if state.inFlight[key] != nil {
                state.inFlight[key]?.append(completion)
                return
            }
            state.inFlight[key] = [completion]

            workerQueue.async { [self] in
                let cgImage: CGImage?
                switch file.category {
                case .image, .screenshot:
                    cgImage = Self.decodeImage(at: file.url, pixelSize: pixelSize)
                case .video:
                    cgImage = Self.decodeVideo(at: file.url, size: size)
                default:
                    cgImage = nil
                }

                DispatchQueue.main.async { [self] in
                    finish(cgImage: cgImage, for: key)
                }
            }
        }
    }

    private func finish(cgImage: CGImage?, for key: ZoneFileThumbnailCacheKey) {
        let image = cgImage.map { NSImage(cgImage: $0, size: .zero) }
        if let image {
            cache.setObject(image, forKey: WrappedKey(key))
        }

        let completions = stateQueue.sync {
            state.inFlight.removeValue(forKey: key) ?? []
        }
        completions.forEach { $0(image) }
    }

    nonisolated private static func decodeImage(at url: URL, pixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated private static func decodeVideo(at url: URL, size: NSSize) -> CGImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size
        return try? generator.copyCGImage(at: .zero, actualTime: nil)
    }

    private static let supportedCategories: Set<FileCategory> = [
        .image,
        .screenshot,
        .video,
    ]
}
