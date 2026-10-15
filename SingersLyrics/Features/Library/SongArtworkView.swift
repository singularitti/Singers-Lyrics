import OSLog
import SwiftUI
#if os(macOS)
import AppKit
private typealias SongArtworkImage = NSImage
#elseif os(iOS)
import UIKit
private typealias SongArtworkImage = UIImage
#endif

private extension Image {
    init(songArtwork: SongArtworkImage) {
        #if os(macOS)
        self.init(nsImage: songArtwork)
        #elseif os(iOS)
        self.init(uiImage: songArtwork)
        #endif
    }
}

/// Decorative artwork for an Apple Music link. Lookup and download failures keep the placeholder.
@MainActor
struct SongArtworkView: View {
    let appleMusicURL: URL?
    var size: CGFloat = 68

    @State private var artwork: SongArtworkImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.primary.opacity(0.055))

            if let artwork {
                Image(songArtwork: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.34, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
        .task(id: appleMusicURL) {
            artwork = nil
            guard let appleMusicURL else { return }
            let image = await SongArtworkLoader.shared.image(for: appleMusicURL)
            guard !Task.isCancelled else { return }
            artwork = image
        }
    }
}

/// The catalog release year for the linked track; text inherits the surrounding artist style.
@MainActor
struct SongReleaseYearView: View {
    let appleMusicURL: URL?
    @State private var year: Int?

    var body: some View {
        Text(year.map { "· \(String($0))" } ?? "")
        .task(id: appleMusicURL) {
            year = nil
            guard let appleMusicURL else { return }
            let releaseYear = await SongArtworkLoader.shared.releaseYear(for: appleMusicURL)
            guard !Task.isCancelled else { return }
            year = releaseYear
        }
    }
}

/// Main-actor ownership keeps platform images and request bookkeeping off concurrency boundaries.
@MainActor
private final class SongArtworkLoader {
    static let shared = SongArtworkLoader()
    private static let logger = Logger(subsystem: "app.singerslyrics.SingersLyrics", category: "AlbumArtwork")

    private struct LookupKey: Hashable {
        let trackID: String
        let country: String
        var cacheKey: NSString { "\(country):\(trackID)" as NSString }
    }

    private final class CachedImage {
        let image: SongArtworkImage
        let date = Date()
        init(_ image: SongArtworkImage) { self.image = image }
    }

    private struct PendingRequest<Value: Sendable> {
        let token: UUID
        let task: Task<Value?, Never>
        var waiters: Set<UUID>
    }

    private struct CatalogMetadata: Codable, Sendable {
        let releaseYear: Int?
        let artworkURL: URL?
    }

    private final class CachedCatalog {
        let metadata: CatalogMetadata
        init(_ metadata: CatalogMetadata) { self.metadata = metadata }
    }

    private struct LookupResponse: Decodable {
        struct Result: Decodable {
            let trackId: Int64?
            let artworkUrl100: URL?
            let artworkUrl60: URL?
            let releaseDate: String?
        }
        let results: [Result]
    }

    private let cache = NSCache<NSString, CachedImage>()
    private let catalogCache = NSCache<NSString, CachedCatalog>()
    private var failures: [LookupKey: Date] = [:]
    private var catalogFailures: [LookupKey: Date] = [:]
    private var pending: [LookupKey: PendingRequest<SongArtworkImage>] = [:]
    private var pendingCatalog: [LookupKey: PendingRequest<CatalogMetadata>] = [:]
    private let session: URLSession
    private let thumbnailDirectory: URL?
    private let maximumThumbnailBytes = 256 * 1_024

    private init() {
        cache.countLimit = 160
        cache.totalCostLimit = 32 * 1_024 * 1_024
        catalogCache.countLimit = 160
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(
            memoryCapacity: 8 * 1_024 * 1_024,
            diskCapacity: 32 * 1_024 * 1_024,
            diskPath: "SongArtwork"
        )
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        // Album thumbnails can remain useful even when Apple's lookup response has expired.
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: configuration)
        thumbnailDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "SingersLyrics", isDirectory: true)
            .appendingPathComponent("SongArtworkThumbnails", isDirectory: true)
        if let thumbnailDirectory {
            try? FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        }
        pruneDiskCache(fileExtension: "artwork", maximumBytes: 8 * 1_024 * 1_024)
        pruneDiskCache(fileExtension: "catalog", maximumBytes: 1_024 * 1_024)
    }

    func image(for url: URL) async -> SongArtworkImage? {
        guard !Task.isCancelled, let key = lookupKey(for: url) else { return nil }
        return await image(for: key)
    }

    func releaseYear(for url: URL) async -> Int? {
        guard !Task.isCancelled, let key = lookupKey(for: url) else { return nil }
        guard let year = await catalog(for: key)?.releaseYear, (1...9999).contains(year) else { return nil }
        return year
    }

    private func lookupKey(for url: URL) -> LookupKey? {
        guard let trackID = ITunesTrackMetadataService.trackID(from: url) else { return nil }
        let storefront = url.pathComponents.dropFirst().first?.lowercased() ?? ""
        let country = storefront.count == 2 && storefront.utf8.allSatisfy { (97...122).contains($0) }
            ? storefront : "us"
        return LookupKey(trackID: trackID, country: country)
    }

    private func image(for key: LookupKey) async -> SongArtworkImage? {
        if let cached = cache.object(forKey: key.cacheKey) {
            if Date().timeIntervalSince(cached.date) < 24 * 60 * 60 { return cached.image }
            cache.removeObject(forKey: key.cacheKey)
        }
        // Read an already decoded-and-validated success before checking network failure cooldowns.
        // This also makes artwork available after relaunch while offline.
        if let image = diskImage(for: key) {
            cacheImage(image, for: key)
            return image
        }
        if let failed = failures[key], Date().timeIntervalSince(failed) < 90 { return nil }
        failures[key] = nil

        let waiter = UUID()
        let request: PendingRequest<SongArtworkImage>
        if var existing = pending[key] {
            existing.waiters.insert(waiter)
            pending[key] = existing
            request = existing
        } else {
            let token = UUID()
            let task = Task { @MainActor in
                let image = await self.fetchImage(key)
                self.finish(key, token: token, image: image)
                return image
            }
            request = PendingRequest(token: token, task: task, waiters: [waiter])
            pending[key] = request
        }

        let token = request.token
        return await withTaskCancellationHandler {
            defer { release(key, token: token, waiter: waiter) }
            let image = await request.task.value
            return Task.isCancelled ? nil : image
        } onCancel: {
            // A disappearing row releases its interest without interrupting other rows.
            Task { @MainActor in
                self.release(key, token: token, waiter: waiter)
            }
        }
    }

    private func release(_ key: LookupKey, token: UUID, waiter: UUID) {
        guard var request = pending[key], request.token == token else { return }
        request.waiters.remove(waiter)
        if request.waiters.isEmpty {
            pending[key] = nil
            request.task.cancel()
        } else {
            pending[key] = request
        }
    }

    private func finish(_ key: LookupKey, token: UUID, image: SongArtworkImage?) {
        guard pending[key]?.token == token else { return }
        pending[key] = nil
        guard !Task.isCancelled else { return }
        if let image {
            cacheImage(image, for: key)
        } else {
            failures[key] = Date()
            if failures.count > 160, let oldest = failures.min(by: { $0.value < $1.value })?.key {
                failures[oldest] = nil
            }
        }
    }

    /// Artwork and year views each register interest in one shared metadata request.
    private func catalog(for key: LookupKey) async -> CatalogMetadata? {
        guard !Task.isCancelled else { return nil }
        if let cached = catalogCache.object(forKey: key.cacheKey) { return cached.metadata }
        if let file = catalogURL(for: key),
           let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize, size <= 16 * 1_024,
           let data = try? Data(contentsOf: file),
           let metadata = try? JSONDecoder().decode(CatalogMetadata.self, from: data) {
            catalogCache.setObject(CachedCatalog(metadata), forKey: key.cacheKey)
            return metadata
        }
        if let failed = catalogFailures[key], Date().timeIntervalSince(failed) < 90 { return nil }
        catalogFailures[key] = nil

        let waiter = UUID()
        let request: PendingRequest<CatalogMetadata>
        if var existing = pendingCatalog[key] {
            existing.waiters.insert(waiter)
            pendingCatalog[key] = existing
            request = existing
        } else {
            let token = UUID()
            let task = Task { @MainActor in
                let metadata = await self.fetchCatalog(key)
                self.finishCatalog(key, token: token, metadata: metadata)
                return metadata
            }
            request = PendingRequest(token: token, task: task, waiters: [waiter])
            pendingCatalog[key] = request
        }
        let token = request.token
        return await withTaskCancellationHandler {
            defer { releaseCatalog(key, token: token, waiter: waiter) }
            let metadata = await request.task.value
            return Task.isCancelled ? nil : metadata
        } onCancel: {
            Task { @MainActor in
                self.releaseCatalog(key, token: token, waiter: waiter)
            }
        }
    }

    private func releaseCatalog(_ key: LookupKey, token: UUID, waiter: UUID) {
        guard var request = pendingCatalog[key], request.token == token else { return }
        request.waiters.remove(waiter)
        if request.waiters.isEmpty {
            pendingCatalog[key] = nil
            request.task.cancel()
        } else {
            pendingCatalog[key] = request
        }
    }

    private func finishCatalog(_ key: LookupKey, token: UUID, metadata: CatalogMetadata?) {
        guard pendingCatalog[key]?.token == token else { return }
        pendingCatalog[key] = nil
        guard !Task.isCancelled else { return }
        if let metadata {
            catalogCache.setObject(CachedCatalog(metadata), forKey: key.cacheKey)
            if let file = catalogURL(for: key), let data = try? JSONEncoder().encode(metadata),
               data.count <= 16 * 1_024 {
                try? data.write(to: file, options: .atomic)
                pruneDiskCache(fileExtension: "catalog", maximumBytes: 1_024 * 1_024)
            }
        } else {
            catalogFailures[key] = Date()
            if catalogFailures.count > 160,
               let oldest = catalogFailures.min(by: { $0.value < $1.value })?.key {
                catalogFailures[oldest] = nil
            }
        }
    }

    private func fetchCatalog(_ key: LookupKey) async -> CatalogMetadata? {
        do {
            var components = URLComponents(string: "https://itunes.apple.com/lookup")!
            components.queryItems = [
                URLQueryItem(name: "id", value: key.trackID),
                URLQueryItem(name: "country", value: key.country),
            ]
            guard let lookupURL = components.url else { return nil }
            Self.logger.debug("Starting catalog metadata lookup")
            let (data, response) = try await session.data(from: lookupURL)
            Self.logger.debug("Catalog lookup HTTP status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            guard Self.succeeded(response), !Task.isCancelled else { return nil }
            guard let result = try JSONDecoder().decode(LookupResponse.self, from: data).results
                .first(where: { $0.trackId.map(String.init) == key.trackID }) else { return nil }
            return CatalogMetadata(
                releaseYear: Self.releaseYear(from: result.releaseDate),
                artworkURL: result.artworkUrl100 ?? result.artworkUrl60
            )
        } catch {
            Self.logger.debug("Catalog request ended with error code: \((error as NSError).code)")
            return nil
        }
    }

    private static func releaseYear(from releaseDate: String?) -> Int? {
        guard let releaseDate else { return nil }
        let formatter = ISO8601DateFormatter()
        var date = formatter.date(from: releaseDate)
        if date == nil {
            formatter.formatOptions.insert(.withFractionalSeconds)
            date = formatter.date(from: releaseDate)
        }
        guard let date else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = calendar.component(.year, from: date)
        return (1...9999).contains(year) ? year : nil
    }

    private func fetchImage(_ key: LookupKey) async -> SongArtworkImage? {
        do {
            guard let metadata = await catalog(for: key), !Task.isCancelled,
                  let artworkURL = metadata.artworkURL,
                  artworkURL.scheme?.lowercased() == "https" else { return nil }
            let (imageData, imageResponse) = try await session.data(from: artworkURL)
            Self.logger.debug("Artwork download HTTP status: \((imageResponse as? HTTPURLResponse)?.statusCode ?? 0), bytes: \(imageData.count)")
            guard Self.succeeded(imageResponse), !Task.isCancelled else { return nil }
            guard let image = SongArtworkImage(data: imageData) else { return nil }
            if imageData.count <= maximumThumbnailBytes, let file = thumbnailURL(for: key) {
                // Persist only successful image bytes, independently of HTTP cache headers.
                try? imageData.write(to: file, options: .atomic)
                pruneDiskCache(fileExtension: "artwork", maximumBytes: 8 * 1_024 * 1_024)
            }
            return image
        } catch {
            Self.logger.debug("Artwork request ended with error code: \((error as NSError).code)")
            return nil
        }
    }

    private func cacheImage(_ image: SongArtworkImage, for key: LookupKey) {
        #if os(macOS)
        let pixels = image.representations.first
        let cost = (pixels?.pixelsWide ?? 300) * (pixels?.pixelsHigh ?? 300) * 4
        #elseif os(iOS)
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height }
            ?? Int(image.size.width * image.scale) * Int(image.size.height * image.scale) * 4
        #endif
        cache.setObject(CachedImage(image), forKey: key.cacheKey, cost: cost)
    }

    private func thumbnailURL(for key: LookupKey) -> URL? {
        thumbnailDirectory?.appendingPathComponent("\(key.country)-\(key.trackID).artwork")
    }

    private func catalogURL(for key: LookupKey) -> URL? {
        thumbnailDirectory?.appendingPathComponent("\(key.country)-\(key.trackID).catalog")
    }

    private func diskImage(for key: LookupKey) -> SongArtworkImage? {
        guard let file = thumbnailURL(for: key),
              let attributes = try? file.resourceValues(forKeys: [.fileSizeKey]),
              let size = attributes.fileSize, size <= maximumThumbnailBytes else { return nil }
        guard let data = try? Data(contentsOf: file), let image = SongArtworkImage(data: data) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return image
    }

    /// Bound each cache independently, evicting the oldest successful writes first.
    private func pruneDiskCache(fileExtension: String, maximumBytes: Int) {
        guard let thumbnailDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: thumbnailDirectory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: .skipsHiddenFiles
              ) else { return }
        let entries = files.compactMap { file -> (url: URL, size: Int, date: Date)? in
            guard file.pathExtension == fileExtension,
                  let values = try? file.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
                  ), values.isRegularFile == true else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.date < $1.date }
        var bytes = entries.reduce(0) { $0 + $1.size }
        var count = entries.count
        for entry in entries where count > 160 || bytes > maximumBytes {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                count -= 1
                bytes -= entry.size
            }
        }
    }

    private static func succeeded(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}
