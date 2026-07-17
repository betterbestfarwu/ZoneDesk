import Foundation

public enum DesktopFileClassifier {
    public static func classify(url: URL) -> FileCategory {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()

        if name.contains("screen shot")
            || name.contains("screenshot")
            || name.contains("截屏")
            || name.contains("截图") {
            return .screenshot
        }

        if ext == "app" {
            return .app
        }

        if ["png", "jpg", "jpeg", "heic", "webp", "gif", "tiff", "bmp"].contains(ext) {
            return .image
        }

        if ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "rtf", "pages", "numbers", "key"].contains(ext) {
            return .document
        }

        if ["zip", "dmg", "rar", "7z", "tar", "gz", "bz2", "xz"].contains(ext) {
            return .archive
        }

        if ["mp4", "mov", "mkv", "avi", "m4v", "webm"].contains(ext) {
            return .video
        }

        return .other
    }
}
