import SwiftUI

struct RootView: View {
    @State private var selection = RootView.initialTab

    var body: some View {
        switch Self.launchMode {
        case .channel(let source):
            PlayerView(source: source)
        case .recording:
            RecordingAutoPlayer()
        case .favorite:
            FavoriteAutoPlayer()
        case .addFavorite:
            AddFavoriteView()
        case .chooser:
            ChooserAutoView()
        case .editFavorite:
            EditFavoriteAutoView()
        case nil:
            tabs
        }
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            ChannelBrowserView()
                .tabItem {
                    Label("Tiešraide", systemImage: "tv")
                }
                .tag(0)
            ScheduleView()
                .tabItem {
                    Label("Programma", systemImage: "calendar")
                }
                .tag(1)
            ArchiveView()
                .tabItem {
                    Label("Arhīvs", systemImage: "film.stack")
                }
                .tag(2)
        }
    }

    // MARK: - Debug launch arguments

    /// `-startTab schedule|archive` opens that tab; `-play ltv1|ltv7|recording`
    /// goes straight to a player. Used for screenshots and UI testing.
    private enum LaunchMode {
        case channel(PlaybackSource)
        case recording
        case favorite
        case addFavorite
        case chooser
        case editFavorite
    }

    private static let launchMode: LaunchMode? = {
        guard DebugHooks.isEnabled else { return nil }
        switch DebugHooks.string("play") {
        case "ltv1": return .channel(.live(LiveChannel.catalogue[0]))
        case "ltv7": return .channel(.live(LiveChannel.catalogue[1]))
        case "recording": return .recording
        case "favorite": return .favorite
        case "addFavorite": return .addFavorite
        case "chooser": return .chooser
        case "editFavorite": return .editFavorite
        default: return nil
        }
    }()

    private static let initialTab: Int = {
        switch DebugHooks.string("startTab") {
        case "schedule": return 1
        case "archive": return 2
        default: return 0
        }
    }()
}

/// Opens the editor for the first saved favourite.
private struct EditFavoriteAutoView: View {
    var body: some View {
        if let favorite = FavoritesStore.shared.favorites.first {
            AddFavoriteView(editing: favorite)
        } else {
            Text("No favourites saved.")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

/// Shows the multi-match chooser for a broad favourite such as "sport".
private struct ChooserAutoView: View {
    @State private var chooser: Chooser?
    @State private var message: String?

    var body: some View {
        Group {
            if let chooser {
                MatchChooserView(chooser: chooser) { _ in }
            } else if let message {
                Text(message)
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                ProgressView()
            }
        }
        .task {
            guard let favorite = FavoritesStore.shared.favorites.first(where: { $0.startMinutes == nil }) else {
                message = "No broad favourite saved."
                return
            }
            let matches = await FavoriteResolver.matches(for: favorite)
            chooser = Chooser(favorite: favorite, matches: matches)
        }
    }
}

/// Resolves the first favourite against today's schedule and plays it.
private struct FavoriteAutoPlayer: View {
    @State private var source: PlaybackSource?
    @State private var favorite: Favorite?
    @State private var message: String?

    var body: some View {
        Group {
            if let source {
                PlayerView(source: source, favorite: favorite)
            } else if let message {
                Text(message)
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                ProgressView()
            }
        }
        .task {
            guard let favorite = FavoritesStore.shared.favorites.first else {
                message = "No favourites saved."
                return
            }
            let matches = await FavoriteResolver.matches(for: favorite)
            if let first = matches.first {
                self.favorite = favorite
                source = FavoriteResolver.source(for: first)
            } else {
                message = "No match today for \(favorite.title)."
            }
        }
    }
}

/// Resolves the first playable recording from yesterday and plays it.
private struct RecordingAutoPlayer: View {
    @State private var source: PlaybackSource?
    @State private var message: String?

    var body: some View {
        Group {
            if let source {
                PlayerView(source: source)
            } else if let message {
                Text(message)
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                ProgressView()
            }
        }
        .task {
            do {
                let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
                let guide = try await ReplayService.shared.guide(
                    channel: LiveChannel.catalogue[0],
                    day: yesterday
                )
                if let entry = guide.first(where: \.isPlayableRecording) {
                    source = .recording(entry)
                } else {
                    message = "No playable recording found."
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
