import AppKit
import Observation
import QuickLookThumbnailing

extension DownloadHistory {
    static let shared = DownloadHistory(file: JSONStore("downloads.json"))

    /// Quick Look thumbnails by path, made on demand (DownloadThumbnails).
    var thumbnails: [String: NSImage] { DownloadThumbnails.shared.images }

    func thumbnail(for path: String) -> NSImage? { DownloadThumbnails.shared.thumbnail(for: path) }
}

/// The downloads list's Quick Look thumbnails, by path.
@MainActor
@Observable
final class DownloadThumbnails {
    static let shared = DownloadThumbnails()

    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    func thumbnail(for path: String) -> NSImage? {
        if let image = images[path] { return image }
        load(path)
        return nil
    }

    private func load(_ path: String) {
        guard !loading.contains(path) else { return }
        loading.insert(path)
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 40, height: 40),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            let image = thumbnail?.nsImage
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading.remove(path)
                self.images[path] = image ?? NSWorkspace.shared.icon(forFile: path)
            }
        }
    }
}
