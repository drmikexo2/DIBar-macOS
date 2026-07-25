import AppKit
import SwiftUI

/// One shared in-memory cache for track artwork, so the history list doesn't
/// re-download thumbnails as rows recycle and the player reuses now-playing
/// art across track repeats. In-flight requests are deduped.
@MainActor
enum ArtCache {
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 200
        cache.totalCostLimit = 20 * 1024 * 1024
        return cache
    }()

    private static var inflight: [URL: Task<NSImage?, Never>] = [:]

    static func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    static func image(for url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        if let pending = inflight[url] { return await pending.value }
        let task = Task { () -> NSImage? in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data)
            else { return nil }
            cache.setObject(image, forKey: url as NSURL, cost: data.count)
            return image
        }
        inflight[url] = task
        let image = await task.value
        inflight[url] = nil
        return image
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
