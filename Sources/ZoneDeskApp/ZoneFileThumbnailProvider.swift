import AppKit
import AVFoundation
import ImageIO
import ZoneDeskCore

private typealias ZoneFileThumbnailCompletion = (NSImage?) -> Void
typealias ZoneFileThumbnailDecoder = (ZoneStoredFile, NSSize) -> CGImage?

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
    let pixelWidth: Int
    let pixelHeight: Int

    init(url: URL, modificationDate: Date?, pixelSize: Int) {
        self.init(
            url: url,
            modificationDate: modificationDate,
            pixelWidth: pixelSize,
            pixelHeight: pixelSize
        )
    }

    init(
        url: URL,
        modificationDate: Date?,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.url = url.standardizedFileURL
        self.modificationDate = modificationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
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
    private let decoder: ZoneFileThumbnailDecoder

    init() {
        decoder = Self.decodeThumbnail
    }

    init(decoder: @escaping ZoneFileThumbnailDecoder) {
        self.decoder = decoder
    }

    func thumbnail(
        for file: ZoneStoredFile,
        size: NSSize,
        completion: @escaping (NSImage?) -> Void
    ) {
        guard !file.isDirectory,
              Self.supportedCategories.contains(file.category),
              let pixelDimensions = Self.normalizedPixelDimensions(for: size) else {
            completion(nil)
            return
        }

        let key = ZoneFileThumbnailCacheKey(
            url: file.url,
            modificationDate: file.modificationDate,
            pixelWidth: pixelDimensions.width,
            pixelHeight: pixelDimensions.height
        )
        if let image = cache.object(forKey: WrappedKey(key)) {
            completion(image)
            return
        }

        let normalizedSize = NSSize(
            width: pixelDimensions.width,
            height: pixelDimensions.height
        )
        let state = state
        let stateQueue = stateQueue
        let workerQueue = workerQueue
        let shouldDecode = stateQueue.sync {
            if state.inFlight[key] != nil {
                state.inFlight[key]?.append(completion)
                return false
            }
            state.inFlight[key] = [completion]
            return true
        }
        guard shouldDecode else {
            return
        }

        let decoder = decoder
        workerQueue.async { [self] in
            let cgImage = decoder(file, normalizedSize)
            DispatchQueue.main.async { [self] in
                finish(cgImage: cgImage, for: key)
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

    nonisolated private static func normalizedPixelDimensions(
        for size: NSSize
    ) -> (width: Int, height: Int)? {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0,
              let width = Int(exactly: ceil(size.width)),
              let height = Int(exactly: ceil(size.height)),
              width > 0,
              height > 0 else {
            return nil
        }
        return (width, height)
    }

    nonisolated private static func decodeThumbnail(
        for file: ZoneStoredFile,
        size: NSSize
    ) -> CGImage? {
        switch file.category {
        case .image, .screenshot:
            return decodeImage(at: file.url, size: size)
        case .video:
            return decodeVideo(at: file.url, size: size)
        default:
            return nil
        }
    }

    nonisolated private static func decodeImage(at url: URL, size: NSSize) -> CGImage? {
        guard let pixelDimensions = normalizedPixelDimensions(for: size),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let maximumPixelSize = max(pixelDimensions.width, pixelDimensions.height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        return aspectFit(
            thumbnail,
            pixelWidth: pixelDimensions.width,
            pixelHeight: pixelDimensions.height
        )
    }

    nonisolated private static func aspectFit(
        _ image: CGImage,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> CGImage? {
        guard image.width > pixelWidth || image.height > pixelHeight else {
            return image
        }

        let scale = min(
            Double(pixelWidth) / Double(image.width),
            Double(pixelHeight) / Double(image.height)
        )
        let fittedWidth = max(
            1,
            min(pixelWidth, Int(floor(Double(image.width) * scale)))
        )
        let fittedHeight = max(
            1,
            min(pixelHeight, Int(floor(Double(image.height) * scale)))
        )
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: fittedWidth,
            height: fittedHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: fittedWidth, height: fittedHeight)
        )
        return context.makeImage()
    }

    nonisolated private static func decodeVideo(at url: URL, size: NSSize) -> CGImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        configureVideoGenerator(generator, maximumSize: size)
        return try? generator.copyCGImage(at: .zero, actualTime: nil)
    }

    nonisolated static func configureVideoGenerator(
        _ generator: AVAssetImageGenerator,
        maximumSize: NSSize
    ) {
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
    }

    private static let supportedCategories: Set<FileCategory> = [
        .image,
        .screenshot,
        .video,
    ]
}
