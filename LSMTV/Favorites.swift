import Foundation
import UIKit

/// A show pinned to the home screen.
///
/// A favourite is a *query*: a title fragment, optionally narrowed to a start
/// time and a channel. Selecting it resolves against today's schedule, which
/// is what lets "Panorāma 20:00" become a one-click shortcut.
struct Favorite: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var query: String
    /// Minutes since midnight, when the user pinned a specific airing.
    var startMinutes: Int?
    var channelExternalID: String?
    var posterFileName: String?
    var createdAt: Date
}

/// One scheduled airing that a favourite resolved to.
struct FavoriteMatch: Identifiable, Hashable {
    let programmeID: Int
    let title: String
    let channel: LiveChannel
    let start: Date
    let end: Date

    var id: Int { programmeID }
}

@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published private(set) var favorites: [Favorite] = []

    private let directory: URL
    private let defaultsKey = "favorites.v1"

    private init() {
        directory = Self.makeWritableDirectory()
        load()
    }

    /// tvOS only permits writing inside `Library/Caches` (Application Support
    /// and Documents are denied), so poster images live there. The favourites
    /// themselves are kept in UserDefaults, which survives cache purges.
    private static func makeWritableDirectory() -> URL {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        candidates.append(contentsOf: fileManager.urls(for: .cachesDirectory, in: .userDomainMask))
        candidates.append(fileManager.temporaryDirectory)

        for base in candidates {
            let directory = base.appendingPathComponent("LSMTV", isDirectory: true)
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                return directory
            } catch {
                print("[LSMTV] store: \(base.lastPathComponent) unusable \(error)")
            }
        }
        return fileManager.temporaryDirectory.appendingPathComponent("LSMTV", isDirectory: true)
    }

    func add(_ favorite: Favorite) {
        favorites.append(favorite)
        save()
    }

    func remove(_ favorite: Favorite) {
        favorites.removeAll { $0.id == favorite.id }
        if let name = favorite.posterFileName {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        save()
    }

    /// Replaces a favourite in place, cleaning up a replaced poster.
    func update(_ favorite: Favorite) {
        guard let index = favorites.firstIndex(where: { $0.id == favorite.id }) else { return }
        let previousPoster = favorites[index].posterFileName
        if previousPoster != favorite.posterFileName, let previousPoster {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(previousPoster))
        }
        favorites[index] = favorite
        save()
    }

    var postersDirectory: URL { directory }

    func posterURL(for favorite: Favorite) -> URL? {
        guard let name = favorite.posterFileName else { return nil }
        return directory.appendingPathComponent(name)
    }

    /// Stores a downscaled poster and returns its file name.
    func savePoster(_ image: UIImage) -> String? {
        // Normalise first: frames captured from video can carry a scale or
        // colour-space that fails to encode directly.
        let source = image.cgImage.map { UIImage(cgImage: $0) } ?? image
        let target = CGSize(width: 960, height: 540)
        let renderer = UIGraphicsImageRenderer(size: target)
        let scaled = renderer.image { _ in
            let aspect = source.size.width / max(source.size.height, 1)
            var rect = CGRect(origin: .zero, size: target)
            if aspect > target.width / target.height {
                rect.size.width = target.height * aspect
                rect.origin.x = (target.width - rect.size.width) / 2
            } else {
                rect.size.height = target.width / aspect
                rect.origin.y = (target.height - rect.size.height) / 2
            }
            source.draw(in: rect)
        }
        guard let data = scaled.jpegData(compressionQuality: 0.82) ?? scaled.pngData() else {
            print("[LSMTV] poster: encode failed size=\(scaled.size)")
            return nil
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("[LSMTV] poster: directory create failed \(error)")
        }
        let name = "poster-\(UUID().uuidString).jpg"
        do {
            try data.write(to: directory.appendingPathComponent(name))
            return name
        } catch {
            print("[LSMTV] poster: write failed \(error)")
            return nil
        }
    }

    func image(for favorite: Favorite) -> UIImage? {
        guard let url = posterURL(for: favorite) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([Favorite].self, from: data) {
            favorites = decoded
            return
        }

        // Migrate favourites written by older builds into the same directory.
        let legacy = directory.appendingPathComponent("favorites.json")
        if let data = try? Data(contentsOf: legacy),
           let decoded = try? JSONDecoder().decode([Favorite].self, from: data) {
            favorites = decoded
            save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

enum FavoriteResolver {
    /// Today's airings that match the favourite.
    static func matches(for favorite: Favorite, on day: Date = Date()) async -> [FavoriteMatch] {
        let channels: [LiveChannel]
        if let externalID = favorite.channelExternalID,
           let channel = LiveChannel.catalogue.first(where: { $0.externalID == externalID }) {
            channels = [channel]
        } else {
            channels = LiveChannel.catalogue
        }

        var results: [FavoriteMatch] = []
        for channel in channels {
            let schedule = await LSMService.shared.schedule(for: channel, day: day)
            for programme in schedule where matches(programme, favorite: favorite) {
                guard let start = programme.since, let end = programme.till else { continue }
                results.append(
                    FavoriteMatch(
                        programmeID: programme.id,
                        title: programme.title,
                        channel: channel,
                        start: start,
                        end: end
                    )
                )
            }
        }
        return results.sorted { $0.start < $1.start }
    }

    static func matches(_ programme: Programme, favorite: Favorite) -> Bool {
        let query = favorite.query.searchNormalized
        guard titleMatches(programme.title, query: query) else { return false }

        if let wanted = favorite.startMinutes {
            guard let start = programme.since,
                  let minutes = Self.minutesSinceMidnight(start) else { return false }
            // Allow a minute of rounding slack.
            if abs(minutes - wanted) > 1 { return false }
        }
        return true
    }

    /// What pressing the favourite should do right now.
    static func source(for match: FavoriteMatch, now: Date = Date()) -> PlaybackSource {
        if now < match.start {
            return .live(match.channel)
        }
        if now < match.end {
            return .liveWindow(match.channel, from: match.start, to: nil)
        }
        return .liveWindow(match.channel, from: match.start, to: match.end)
    }

    static func minutesSinceMidnight(_ date: Date) -> Int? {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return nil }
        return hour * 60 + minute
    }

    /// The most recent airing that has already started, used to sample poster
    /// frames for a show that may not have aired yet today.
    static func latestPastOccurrence(
        title: String,
        channel: LiveChannel,
        now: Date = Date()
    ) async -> FavoriteMatch? {
        let target = title.searchNormalized
        for offset in 0...7 {
            guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: now) else { continue }
            let schedule = await LSMService.shared.schedule(for: channel, day: day)
            let occurrences = schedule
                .filter { $0.title.searchNormalized == target }
                .compactMap { programme -> FavoriteMatch? in
                    guard let start = programme.since, let end = programme.till, start < now else { return nil }
                    return FavoriteMatch(
                        programmeID: programme.id,
                        title: programme.title,
                        channel: channel,
                        start: start,
                        end: end
                    )
                }
                .sorted { $0.start > $1.start }
            if let latest = occurrences.first { return latest }
        }
        return nil
    }

    /// An airing whose stream can be sampled for a poster: the latest past
    /// occurrence of the exact title, or today's first match for broad queries.
    static func posterSource(for favorite: Favorite, now: Date = Date()) async -> FavoriteMatch? {
        let channel = favorite.channelExternalID.flatMap { externalID in
            LiveChannel.catalogue.first { $0.externalID == externalID }
        }
        if let channel,
           let past = await latestPastOccurrence(title: favorite.title, channel: channel, now: now) {
            return past
        }
        return await matches(for: favorite, on: now).first
    }

    /// One distinct airing pattern found while searching ("Panorāma, 20:00, LTV1").
    struct SearchCandidate: Identifiable, Hashable {
        let id: String
        let title: String
        let channel: LiveChannel
        let startMinutes: Int
        let exampleStart: Date
    }

    /// Searches a week of the schedule around today for matching airings.
    static func search(query: String, startMinutes: Int?) async -> [SearchCandidate] {
        let needle = query.searchNormalized
        guard !needle.isEmpty else { return [] }

        let now = Date()
        var found: [String: SearchCandidate] = [:]

        await withTaskGroup(of: (LiveChannel, [Programme]).self) { group in
            for offset in -1...6 {
                guard let day = Calendar.current.date(byAdding: .day, value: offset, to: now) else { continue }
                for channel in LiveChannel.catalogue {
                    group.addTask {
                        (channel, await LSMService.shared.schedule(for: channel, day: day))
                    }
                }
            }

            for await (channel, schedule) in group {
                for programme in schedule {
                    guard titleMatches(programme.title, query: needle),
                          let start = programme.since,
                          let minutes = minutesSinceMidnight(start) else { continue }
                    if let wanted = startMinutes, abs(minutes - wanted) > 1 { continue }

                    let key = "\(programme.title.searchNormalized)|\(channel.externalID)|\(minutes)"
                    if let existing = found[key] {
                        // Prefer the airing closest to now.
                        if abs(start.timeIntervalSince(now)) < abs(existing.exampleStart.timeIntervalSince(now)) {
                            found[key] = SearchCandidate(
                                id: key,
                                title: programme.title,
                                channel: channel,
                                startMinutes: minutes,
                                exampleStart: start
                            )
                        }
                    } else {
                        found[key] = SearchCandidate(
                            id: key,
                            title: programme.title,
                            channel: channel,
                            startMinutes: minutes,
                            exampleStart: start
                        )
                    }
                }
            }
        }

        return found.values.sorted {
            ($0.title, $0.startMinutes) < ($1.title, $1.startMinutes)
        }
    }

    /// Word-prefix matching, so "sport" finds "Sporta ziņas" but not
    /// "pašportrets"; multi-word queries fall back to a phrase match.
    static func titleMatches(_ title: String, query: String) -> Bool {
        let normalizedTitle = title.searchNormalized
        let normalizedQuery = query.searchNormalized
        guard !normalizedQuery.isEmpty else { return false }
        if normalizedQuery.contains(" ") {
            return normalizedTitle.contains(normalizedQuery)
        }
        return normalizedTitle
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains { $0.hasPrefix(normalizedQuery) }
    }
}

extension String {
    /// Case- and diacritic-insensitive matching, with LTV's asterisks ignored.
    var searchNormalized: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "lv_LV"))
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
