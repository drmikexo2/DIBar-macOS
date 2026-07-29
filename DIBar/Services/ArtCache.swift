import AppKit
import SwiftUI

/// One shared in-memory cache for track artwork, so the history list doesn't
/// re-download thumbnails as rows recycle and the player reuses now-playing
/// art across track repeats. In-flight requests are deduped.
@MainActor
enum ArtCache {
    static let countLimit = 48
    static let totalCostLimit = 16 * 1024 * 1024

    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
        return cache
    }()

    /// Artwork already has its own bounded image cache, so using the shared
    /// URL cache would retain a second copy of every response.
    private static let session = URLSession(configuration: makeSessionConfiguration())
    private static var inflight: [URL: Task<NSImage?, Never>] = [:]

    static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    /// NSImage commonly retains a compressed representation and lazily
    /// materializes decoded pixels. Charge the larger of those two costs so
    /// NSCache's limit describes the real working set rather than JPEG size.
    static func imageCost(
        pixelWidth: Int,
        pixelHeight: Int,
        downloadedByteCount: Int
    ) -> Int {
        let downloaded = max(downloadedByteCount, 0)
        guard pixelWidth > 0, pixelHeight > 0 else { return downloaded }

        let (pixels, pixelOverflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        guard !pixelOverflow else { return downloaded }
        let (decodedBytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        guard !byteOverflow else { return downloaded }
        return max(downloaded, decodedBytes)
    }

    private static func imageCost(for image: NSImage, downloadedByteCount: Int) -> Int {
        let largestRepresentation = image.representations.max {
            $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
        }
        return imageCost(
            pixelWidth: largestRepresentation?.pixelsWide ?? 0,
            pixelHeight: largestRepresentation?.pixelsHigh ?? 0,
            downloadedByteCount: downloadedByteCount
        )
    }

    static func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    static func image(for url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        if let pending = inflight[url] { return await pending.value }
        let task = Task { () -> NSImage? in
            guard let (data, _) = try? await session.data(from: url),
                  let image = NSImage(data: data)
            else { return nil }
            cache.setObject(
                image,
                forKey: url as NSURL,
                cost: imageCost(for: image, downloadedByteCount: data.count)
            )
            return image
        }
        inflight[url] = task
        defer { inflight[url] = nil }
        return await task.value
    }
}

/// Drop-in AsyncImage replacement backed by ArtCache: cached images render
/// synchronously, so list rows don't flicker through the placeholder while
/// scrolling.
struct CachedArtImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var loaded: LoadedImage?

    private struct LoadedImage {
        let url: URL
        let image: NSImage
    }

    // The loaded state is keyed to its URL so a recycled row never shows the
    // previous row's art while the new one downloads.
    private var displayImage: NSImage? {
        guard let url else { return nil }
        if let cached = ArtCache.cached(url) { return cached }
        return loaded?.url == url ? loaded?.image : nil
    }

    var body: some View {
        Group {
            if let image = displayImage {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url, ArtCache.cached(url) == nil else { return }
            if let image = await ArtCache.image(for: url) {
                loaded = LoadedImage(url: url, image: image)
            }
        }
    }
}
