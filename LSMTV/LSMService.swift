import Foundation

enum LSMError: LocalizedError {
    case badURL
    case http(Int)
    case noStream
    case unexpectedResponse
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "The channel address could not be built."
        case .http(let code):
            return "LSM returned HTTP \(code)."
        case .noStream:
            return "No stream is available for this item."
        case .unexpectedResponse:
            return "LSM sent an unexpected response."
        case .decoding:
            return "LSM's response could not be read."
        }
    }
}

/// Talks to the Redge Media backend that powers replay.lsm.lv.
///
/// Playback is a three-step dance:
/// 1. resolve the asset (live channel, EPG entry or archive item),
/// 2. exchange it for a player configuration carrying a short-lived `cdnToken`,
/// 3. fetch the playlist, whose HLS entry already contains that token.
struct LSMService {
    static let shared = LSMService()

    private let base = URL(string: "https://telpa.lsm.lv")!
    private let tenant = "LsmP"
    private let session: URLSession
    private let decoder: JSONDecoder

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Live channels

    /// The known channels, enriched with the logos published by the LSM live API.
    func channels() async -> [LiveChannel] {
        var catalogue = LiveChannel.catalogue
        guard let items = try? await liveItems() else { return catalogue }
        for index in catalogue.indices where catalogue[index].logoURL == nil {
            let externalID = catalogue[index].externalID
            catalogue[index].logoURL = items.first { $0.externalUid == externalID }?.logoURL
        }
        return catalogue
    }

    private func liveItems() async throws -> [LiveItem] {
        var components = URLComponents(
            url: base.appendingPathComponent("api/products/lives"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "platform", value: "BROWSER"),
            URLQueryItem(name: "tenantUid", value: tenant),
            URLQueryItem(name: "maxResults", value: "100"),
        ]
        guard let url = components.url else { throw LSMError.badURL }
        let list: LiveList = try await get(url)
        return list.items
    }

    // MARK: - Schedule

    /// Programmes airing on `channel` during the local day containing `day`.
    func schedule(for channel: LiveChannel, day: Date) async -> [Programme] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }

        let query = "platform=BROWSER&tenantUid=\(tenant)"
            + "&liveId[]=\(channel.assetID)"
            + "&since=\(Self.wireTimestamp(start))&till=\(Self.wireTimestamp(end))"
        guard let url = try? endpoint(path: "api/products/lives/programmes", query: query),
              let programmes: [Programme] = try? await get(url) else {
            return []
        }
        return programmes.sorted { ($0.since ?? .distantPast) < ($1.since ?? .distantPast) }
    }

    func nowPlaying(for channel: LiveChannel) async -> Programme? {
        let stamp = Self.wireTimestamp(Date())
        let query = "platform=BROWSER&tenantUid=\(tenant)"
            + "&liveId[]=\(channel.assetID)&since=\(stamp)&till=\(stamp)"
        guard let url = try? endpoint(path: "api/products/lives/programmes", query: query),
              let programmes: [Programme] = try? await get(url) else {
            return nil
        }
        return programmes.first
    }

    // MARK: - Archive

    /// Every on-demand film, documentary and children's title in the catalogue.
    func archive() async throws -> [ArchiveItem] {
        var components = URLComponents(
            url: base.appendingPathComponent("api/products/vods"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "platform", value: "BROWSER"),
            URLQueryItem(name: "tenantUid", value: tenant),
            URLQueryItem(name: "maxResults", value: "500"),
        ]
        guard let url = components.url else { throw LSMError.badURL }
        let list: VODList = try await get(url)

        return list.items
            .filter { $0.type == "VOD" }
            .map {
                ArchiveItem(
                    id: $0.id,
                    title: $0.title,
                    lead: $0.lead ?? "",
                    since: $0.since,
                    category: $0.mainCategory?.name,
                    imageURL: $0.images?.wide?.first?.url.url
                )
            }
    }

    // MARK: - Playback

    /// Live channel stream. `start`/`end` turn the playlist into a timeshift
    /// window; the CDN accepts roughly seven days back.
    func livePlayback(
        for channel: LiveChannel,
        from start: Date? = nil,
        to end: Date? = nil
    ) async throws -> PlaybackDescriptor {
        let descriptor = try await playback(assetID: channel.assetID, videoType: "LIVE", isLive: true)
        guard start != nil || end != nil else { return descriptor }

        var urlString = descriptor.url.absoluteString
        if let start { urlString += "&startTime=\(Self.cdnMilliseconds(start))" }
        if let end { urlString += "&stopTime=\(Self.cdnMilliseconds(end))" }

        guard let url = URL(string: urlString) else { return descriptor }
        return PlaybackDescriptor(url: url, isLive: end == nil, fairPlay: descriptor.fairPlay)
    }

    /// The CDN wants milliseconds since the 1904 (CoreMedia) epoch.
    private static func cdnMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 - 978_307_200) * 1000)
    }

    func archivePlayback(for item: ArchiveItem) async throws -> PlaybackDescriptor {
        try await playback(assetID: item.id, videoType: "MOVIE", isLive: false)
    }

    /// A recording resolved from the replay guide (telpa `EPISODE` product).
    func recordingPlayback(assetID: Int) async throws -> PlaybackDescriptor {
        try await playback(assetID: assetID, videoType: "MOVIE", isLive: false)
    }

    private func playback(assetID: Int, videoType: String, isLive: Bool) async throws -> PlaybackDescriptor {
        let configurationURL = try endpoint(
            path: "api/products/\(assetID)/videos/player/configuration",
            query: "platform=BROWSER&videoType=\(videoType)&tenantUid=\(tenant)"
        )
        let configuration: PlayerConfiguration = try await get(configurationURL)
        let playlist: Playlist = try await get(configuration.playlistUrl)

        guard let source = playlist.sources.hls.first?.src.url else {
            throw LSMError.noStream
        }
        return PlaybackDescriptor(url: source, isLive: isLive, fairPlay: playlist.fairPlay)
    }

    /// The programmes endpoint expects `2026-10-29T15:39+0000`, where the
    /// `+` must stay percent-encoded or the server reads it as a space.
    private static func wireTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.string(from: date) + "%2B0000"
    }

    // MARK: - Networking

    private func endpoint(path: String, query: String? = nil) throws -> URL {
        guard var components = URLComponents(
            url: base.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw LSMError.badURL
        }
        if let query {
            // Brackets are legal in a query but `URL(string:)` rejects them, so
            // keep the string fully percent-encoded and let URLComponents carry it.
            components.percentEncodedQuery = query
                .replacingOccurrences(of: "[", with: "%5B")
                .replacingOccurrences(of: "]", with: "%5D")
        }
        guard let url = components.url else { throw LSMError.badURL }
        return url
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LSMTV/1.0 (tvOS)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LSMError.unexpectedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LSMError.http(http.statusCode)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw LSMError.decoding(error)
        }
    }
}

// MARK: - Wire models

/// The API returns protocol-relative URLs (`//r.dcs.redcdn.pl/...`).
private struct RemoteURL: Decodable {
    let url: URL

    enum CodingKeys: String, CodingKey { case url }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let absolute = raw.hasPrefix("//") ? "https:" + raw : raw
        guard let url = URL(string: absolute) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid URL: \(raw)"
            )
        }
        self.url = url
    }
}

private struct LiveList: Decodable {
    let items: [LiveItem]
}

private struct LiveItem: Decodable {
    let id: Int
    let externalUid: String?
    let images: Images?

    var logoURL: URL? { images?.wide?.first?.url.url }
}

private struct WireImage: Decodable {
    let url: RemoteURL
}

private struct Images: Decodable {
    let wide: [WireImage]?

    enum CodingKeys: String, CodingKey { case wide = "16x9" }
}

private struct VODList: Decodable {
    let items: [VODItem]
}

private struct VODItem: Decodable {
    let id: Int
    let type: String
    let title: String
    let lead: String?
    let since: Date?
    let images: Images?
    let mainCategory: Category?
}

private struct Category: Decodable {
    let name: String?
}

private struct PlayerConfiguration: Decodable {
    let playlistUrl: URL
}

private struct Playlist: Decodable {
    let sources: Sources
    let drm: DRMConfiguration?

    var fairPlay: PlaybackDescriptor.FairPlay? {
        guard let fairplay = drm?.fairplay else { return nil }
        return PlaybackDescriptor.FairPlay(
            certificateURL: fairplay.cert.url,
            licenseURL: fairplay.src.url
        )
    }
}

private struct Sources: Decodable {
    let hls: [Source]

    enum CodingKeys: String, CodingKey { case hls = "HLS" }
}

private struct Source: Decodable {
    let src: RemoteURL
}

private struct DRMConfiguration: Decodable {
    let fairplay: FairPlaySource?

    enum CodingKeys: String, CodingKey { case fairplay = "FAIRPLAY" }
}

private struct FairPlaySource: Decodable {
    let src: RemoteURL
    let cert: RemoteURL
}
