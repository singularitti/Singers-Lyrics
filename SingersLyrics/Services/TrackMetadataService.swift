import Foundation

protocol TrackMetadataLookingUp: Sendable {
    func lookup(url: URL) async throws -> TrackMetadata?
}

struct UITestTrackMetadataService: TrackMetadataLookingUp {
    func lookup(url: URL) async throws -> TrackMetadata? {
        switch ITunesTrackMetadataService.trackID(from: url) {
        case "111":
            TrackMetadata(title: "Alpha", artist: "First Singer")
        case "222":
            TrackMetadata(title: "Zulu", artist: "Second Singer")
        default:
            TrackMetadata(title: "Looked Up Song", artist: "Looked Up Singer")
        }
    }
}

enum TrackMetadataError: LocalizedError, Equatable {
    case unsupportedURL
    case invalidResponse
    case trackNotFound

    var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            "Enter a valid HTTPS link from music.apple.com."
        case .invalidResponse:
            "Apple Music metadata could not be loaded."
        case .trackNotFound:
            "No song metadata was found for that Apple Music link."
        }
    }
}

struct ITunesTrackMetadataService: TrackMetadataLookingUp {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func trackID(from url: URL) -> String? {
        let supportedHosts = ["music.apple.com", "geo.music.apple.com"]
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              supportedHosts.contains(host) else {
            return nil
        }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let item = components.queryItems?.first(where: { $0.name == "i" }),
           let value = item.value,
           !value.isEmpty,
           value.allSatisfy(\.isNumber) {
            return value
        }

        if let final = url.pathComponents.last, !final.isEmpty, final.allSatisfy(\.isNumber) {
            return final
        }
        return nil
    }

    func lookup(url: URL) async throws -> TrackMetadata? {
        guard let trackID = Self.trackID(from: url) else {
            throw TrackMetadataError.unsupportedURL
        }
        guard let requestURL = URL(string: "https://itunes.apple.com/lookup?id=\(trackID)") else {
            throw TrackMetadataError.invalidResponse
        }

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 6
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TrackMetadataError.invalidResponse
        }

        struct LookupResponse: Decodable {
            struct Result: Decodable {
                var trackName: String?
                var collectionName: String?
                var artistName: String?
            }
            var results: [Result]
        }

        let result = try JSONDecoder().decode(LookupResponse.self, from: data).results.first
        guard let result else { return nil }
        let title = result.trackName ?? result.collectionName ?? ""
        let artist = result.artistName ?? ""
        return title.isEmpty && artist.isEmpty ? nil : TrackMetadata(title: title, artist: artist)
    }
}
