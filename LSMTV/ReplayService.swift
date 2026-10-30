import Foundation
import JavaScriptCore

enum ReplayError: LocalizedError {
    case payloadMissing
    case badResponse
    case noPlayback
    case noAsset

    var errorDescription: String? {
        switch self {
        case .payloadMissing:
            return "The schedule page could not be read."
        case .badResponse:
            return "replay.lsm.lv sent an unexpected response."
        case .noPlayback:
            return "This programme has no recording."
        case .noAsset:
            return "The recording could not be resolved."
        }
    }
}

/// Reads the editorial replay.lsm.lv guide, which — unlike the telpa EPG —
/// knows which past programmes have a recorded media item attached.
///
/// The guide is a Nuxt server-rendered page that embeds its payload as
/// `window.__REPLAY__ = (function (…) {…})(…)`. We evaluate that expression
/// with JavaScriptCore and take the resulting object as JSON.
struct ReplayService {
    static let shared = ReplayService()

    private let session: URLSession
    private let decoder: JSONDecoder

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Guide

    func guide(channel: LiveChannel, day: Date) async throws -> [GuideEntry] {
        let date = Self.dayFormatter.string(from: day)
        guard let url = URL(string: "https://replay.lsm.lv/lv/skaties/programma/\(channel.externalID)/\(date)") else {
            throw ReplayError.badResponse
        }
        let html = try await text(at: url)
        let json = try payloadJSON(from: html)
        let payload = try decoder.decode(GuidePayload.self, from: Data(json.utf8))
        guard let page = payload.data.first else { return [] }

        return page.guide.compactMap { item in
            GuideEntry(
                id: item.id,
                title: item.title,
                startsAt: item.starts_at,
                endsAt: item.ends_at,
                isVOD: item.isVOD,
                channelExternalID: item.channel?.name,
                media: item.mediaItem.map {
                    ReplayMedia(source: $0.external_source, externalID: $0.external_id, slug: $0.slug)
                }
            )
        }
    }

    // MARK: - Recorded programme resolution

    /// Walks replay page → LTV embed → telpa asset id.
    func playbackAssetID(for media: ReplayMedia) async throws -> Int {
        guard let pageURL = URL(string: "https://replay.lsm.lv/lv/skaties/ieraksts/\(media.source)/\(media.externalID)/\(media.slug)") else {
            throw ReplayError.noPlayback
        }
        let pageHTML = try await text(at: pageURL)
        let json = try payloadJSON(from: pageHTML)
        let payload = try decoder.decode(MediaPagePayload.self, from: Data(json.utf8))
        guard let embed = payload.data.first?.playback?.service.url else {
            throw ReplayError.noPlayback
        }

        let embedHTML = try await text(at: embed)
        guard let assetID = Self.firstMatch(of: #""item_id"\s*:\s*(\d+)"#, in: embedHTML).flatMap(Int.init) else {
            throw ReplayError.noAsset
        }
        return assetID
    }

    // MARK: - Networking

    private func text(at url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ReplayError.badResponse
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func payloadJSON(from html: String) throws -> String {
        guard let start = html.range(of: "window.__REPLAY__="),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex) else {
            throw ReplayError.payloadMissing
        }
        var expression = String(html[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while expression.hasSuffix(";") { expression.removeLast() }

        guard let context = JSContext() else { throw ReplayError.payloadMissing }
        context.exceptionHandler = { _, _ in }
        guard let result = context.evaluateScript("JSON.stringify(\(expression))")?.toString(),
              result != "undefined" else {
            throw ReplayError.payloadMissing
        }
        return result
    }

    private static func firstMatch(of pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else {
            return nil
        }
        return ns.substring(with: match.range(at: 1))
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Riga")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

// MARK: - Wire models

private struct GuidePayload: Decodable {
    let data: [Page]
}

private struct Page: Decodable {
    let guide: [RawGuideItem]
}

private struct RawGuideItem: Decodable {
    let id: Int
    let title: String
    let starts_at: Date?
    let ends_at: Date?
    let isVOD: Bool
    let channel: RawChannel?
    let mediaItem: RawMedia?

    enum CodingKeys: String, CodingKey {
        case id, title, starts_at, ends_at, is_vod, channel, mediaItem
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        starts_at = try container.decodeIfPresent(Date.self, forKey: .starts_at)
        ends_at = try container.decodeIfPresent(Date.self, forKey: .ends_at)
        channel = try container.decodeIfPresent(RawChannel.self, forKey: .channel)
        mediaItem = try container.decodeIfPresent(RawMedia.self, forKey: .mediaItem)

        // The payload stringifies booleans as 0/1.
        if let flag = try? container.decode(Bool.self, forKey: .is_vod) {
            isVOD = flag
        } else {
            isVOD = (try container.decode(Int.self, forKey: .is_vod)) != 0
        }
    }
}

private struct RawChannel: Decodable {
    let name: String
}

private struct RawMedia: Decodable {
    let external_source: String
    let external_id: Int
    let slug: String
}

private struct MediaPagePayload: Decodable {
    let data: [MediaPage]
}

private struct MediaPage: Decodable {
    let playback: Playback?
}

private struct Playback: Decodable {
    let service: Service

    struct Service: Decodable {
        let url: URL
    }
}
