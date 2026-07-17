import Foundation
import Testing
@testable import ZoneDeskCore

@Suite("Desktop file classification")
struct DesktopClassificationTests {
    @Test("classifies screenshots by common English and Chinese names")
    func classifiesScreenshotsByName() {
        #expect(DesktopFileClassifier.classify(url: URL(fileURLWithPath: "/tmp/Screen Shot 2026-07-16.png")) == .screenshot)
        #expect(DesktopFileClassifier.classify(url: URL(fileURLWithPath: "/tmp/截屏2026-07-16 14.20.00.png")) == .screenshot)
    }

    @Test("classifies common desktop file types")
    func classifiesCommonTypes() {
        #expect(DesktopFileClassifier.classify(url: URL(fileURLWithPath: "/tmp/report.pdf")) == .document)
        #expect(DesktopFileClassifier.classify(url: URL(fileURLWithPath: "/tmp/photo.heic")) == .image)
        #expect(DesktopFileClassifier.classify(url: URL(fileURLWithPath: "/tmp/archive.zip")) == .archive)
        #expect(DesktopFileClassifier.classify(url: URL(fileURLWithPath: "/tmp/movie.mov")) == .video)
        #expect(DesktopFileClassifier.classify(url: URL(fileURLWithPath: "/tmp/Tool.app")) == .app)
    }
}
