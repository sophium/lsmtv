import Foundation

/// A live LSM television channel.
struct LiveChannel: Identifiable, Hashable {
    let assetID: Int
    let externalID: String
    let title: String
    let subtitle: String
    var logoURL: URL?

    var id: Int { assetID }

    static let catalogue: [LiveChannel] = [
        LiveChannel(assetID: 6_379_272, externalID: "ltv1", title: "LTV1", subtitle: "Latvija"),
        LiveChannel(assetID: 6_379_368, externalID: "ltv7", title: "LTV7", subtitle: "Latvija"),
    ]
}

/// A programme in a channel's schedule, from the LSM EPG.
struct Programme: Identifiable, Decodable, Hashable {
    let id: Int
    let title: String
    let description: String?
    let since: Date?
    let till: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, description, since, till
    }
}

/// An on-demand item from the LSM archive.
struct ArchiveItem: Identifiable, Hashable {
    let id: Int
    let title: String
    let lead: String
    let since: Date?
    let category: String?
    let imageURL: URL?

    var year: String? {
        guard let since else { return nil }
        return String(Calendar.current.component(.year, from: since))
    }
}

/// A recorded programme attached to a schedule entry on replay.lsm.lv.
struct ReplayMedia: Hashable {
    let source: String
    let externalID: Int
    let slug: String
}

/// One entry in the replay.lsm.lv guide — the schedule that knows which past
/// programmes can actually be played.
struct GuideEntry: Identifiable, Hashable {
    let id: Int
    let title: String
    let startsAt: Date?
    let endsAt: Date?
    let isVOD: Bool
    let channelExternalID: String?
    let media: ReplayMedia?

    var channel: LiveChannel? {
        LiveChannel.catalogue.first { $0.externalID == channelExternalID }
    }

    var isOnNow: Bool {
        guard let startsAt, let endsAt else { return false }
        let now = Date()
        return now >= startsAt && now < endsAt
    }

    /// A past entry is playable when the guide attached a media item to it.
    var isPlayableRecording: Bool {
        media != nil && !isOnNow
    }
}

/// A navigation value: what to play, plus the favourite that led here (if any)
/// so the player can offer to edit it.
struct PlaybackRoute: Hashable {
    let source: PlaybackSource
    var favorite: Favorite?

    init(_ source: PlaybackSource, favorite: Favorite? = nil) {
        self.source = source
        self.favorite = favorite
    }
}

/// Anything the player can open.
enum PlaybackSource: Hashable {
    case live(LiveChannel)
    /// The live channel's timeshift window, starting at `from`. With no `to`
    /// it stays live; with `to` it is a finished programme.
    case liveWindow(LiveChannel, from: Date, to: Date?)
    case archive(ArchiveItem)
    case recording(GuideEntry)

    var title: String {
        switch self {
        case .live(let channel):
            return channel.title
        case .liveWindow(let channel, _, _):
            return channel.title
        case .archive(let item):
            return item.title
        case .recording(let entry):
            return entry.title
        }
    }
}

/// Resolution result for a playable asset.
struct PlaybackDescriptor {
    struct FairPlay {
        let certificateURL: URL
        let licenseURL: URL
    }

    let url: URL
    let isLive: Bool
    let fairPlay: FairPlay?
}
