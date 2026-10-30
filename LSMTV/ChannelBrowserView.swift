import SwiftUI

struct ChannelBrowserView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var store = FavoritesStore.shared

    @State private var channels = LiveChannel.catalogue
    @State private var path = NavigationPath()
    @State private var showAddFavorite = false
    @State private var resolvingFavorite: UUID?
    @State private var chooser: Chooser?
    @State private var pendingRoute: PlaybackRoute?
    @FocusState private var focusedFavorite: UUID?
    @State private var editingFavorite: Favorite?
    @State private var errorMessage: String?

    private let columns = [
        GridItem(.fixed(400), spacing: 44),
        GridItem(.fixed(400), spacing: 44),
        GridItem(.fixed(400), spacing: 44),
    ]

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                TVBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 56) {
                        header

                        LazyVGrid(columns: columns, alignment: .leading, spacing: 48) {
                            ForEach(channels) { channel in
                                NavigationLink(value: PlaybackRoute(.live(channel))) {
                                    ChannelCard(channel: channel)
                                }
                                .buttonStyle(.card)
                            }

                            ForEach(store.favorites) { favorite in
                                Button {
                                    open(favorite)
                                } label: {
                                    FavoriteCard(
                                        favorite: favorite,
                                        isResolving: resolvingFavorite == favorite.id,
                                        isFocused: focusedFavorite == favorite.id
                                    )
                                }
                                .buttonStyle(.card)
                                .focused($focusedFavorite, equals: favorite.id)
                                .contextMenu {
                                    Button {
                                        editingFavorite = favorite
                                    } label: {
                                        Label("Labot favorītu", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        store.remove(favorite)
                                    } label: {
                                        Label("Dzēst favorītu", systemImage: "trash")
                                    }
                                }
                            }

                            Button {
                                showAddFavorite = true
                            } label: {
                                AddFavoriteCard()
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(.horizontal, 120)
                    .padding(.vertical, 80)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollClipDisabled()
            }
            .navigationDestination(for: PlaybackRoute.self) { route in
                PlayerView(source: route.source, favorite: route.favorite) {
                    if !path.isEmpty {
                        path.removeLast()
                    }
                }
            }
        }
        .task {
            if DebugHooks.consume("openAddFavorite") {
                showAddFavorite = true
            }
            if DebugHooks.consume("focusFavorite") {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                focusedFavorite = store.favorites.first?.id
            }
        }
        .task {
            channels = await LSMService.shared.channels()
            if DebugHooks.consumeString("openRoute") == "ltv1", path.isEmpty {
                path.append(PlaybackRoute(.live(channels[0])))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                // tvOS resumes apps where they left off; always come back to
                // the start menu instead of a stale sheet or player.
                path = NavigationPath()
                showAddFavorite = false
                editingFavorite = nil
                chooser = nil
                pendingRoute = nil
            }
        }
        .sheet(isPresented: $showAddFavorite) {
            AddFavoriteView(onFinish: { showAddFavorite = false })
        }
        .sheet(item: $editingFavorite) { favorite in
            AddFavoriteView(editing: favorite, onFinish: { editingFavorite = nil })
        }
        .sheet(item: $chooser, onDismiss: {
            if let pendingRoute {
                self.pendingRoute = nil
                path.append(pendingRoute)
            }
        }) { chooser in
            MatchChooserView(chooser: chooser) { match in
                pendingRoute = PlaybackRoute(
                    FavoriteResolver.source(for: match),
                    favorite: chooser.favorite
                )
                self.chooser = nil
            }
        }
        .alert(
            "Neizdevās",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("Labi", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("LSM TV")
                .font(.system(size: 88, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Latvijas Televīzija · tiešraide")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    // MARK: - Favourite resolution

    private func open(_ favorite: Favorite) {
        guard resolvingFavorite == nil else { return }
        resolvingFavorite = favorite.id

        Task {
            let matches = await FavoriteResolver.matches(for: favorite)
            resolvingFavorite = nil

            if matches.isEmpty {
                if let externalID = favorite.channelExternalID,
                   let channel = LiveChannel.catalogue.first(where: { $0.externalID == externalID }) {
                    path.append(PlaybackRoute(.live(channel), favorite: favorite))
                } else {
                    errorMessage = "Šodien programmā nekas neatbilst “\(favorite.title)”."
                }
            } else if matches.count == 1, let match = matches.first {
                path.append(PlaybackRoute(FavoriteResolver.source(for: match), favorite: favorite))
            } else {
                chooser = Chooser(favorite: favorite, matches: matches)
            }
        }
    }
}

// MARK: - Cards

private struct ChannelCard: View {
    let channel: LiveChannel
    @State private var programme: Programme?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.07))

                artwork

                LiveBadge()
                    .padding(20)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                Text(channel.title)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(programme?.title ?? "Tiešraide")
                    .font(.system(size: 19))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            programme = await LSMService.shared.nowPlaying(for: channel)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let logo = channel.logoURL {
            AsyncImage(url: logo) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFit()
                        .padding(40)
                } else {
                    wordmark
                }
            }
        } else {
            wordmark
        }
    }

    private var wordmark: some View {
        Text(channel.title)
            .font(.system(size: 64, weight: .heavy, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FavoriteCard: View {
    let favorite: Favorite
    let isResolving: Bool
    let isFocused: Bool

    @ObservedObject private var store = FavoritesStore.shared
    @State private var poster: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.07))

                if let poster {
                    Image(uiImage: poster)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    LinearGradient(
                        colors: [Color(red: 0.10, green: 0.18, blue: 0.38), Color(red: 0.03, green: 0.04, blue: 0.09)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Text(favorite.title)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(24)
                }

                if isResolving {
                    Color.black.opacity(0.45)
                    ProgressView()
                }

                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "star.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.yellow.opacity(0.9))
                            .padding(16)
                    }
                    Spacer()
                    if isFocused {
                        HStack(spacing: 8) {
                            Image(systemName: "hand.tap.fill")
                            Text("Turiet Select — labot vai dzēst")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.7), in: Capsule())
                        .padding(.bottom, 12)
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(favorite.title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 19))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: favorite.posterFileName) {
            poster = store.image(for: favorite)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let minutes = favorite.startMinutes {
            parts.append(String(format: "%02d:%02d", minutes / 60, minutes % 60))
        }
        if let externalID = favorite.channelExternalID,
           let channel = LiveChannel.catalogue.first(where: { $0.externalID == externalID }) {
            parts.append(channel.title)
        }
        return parts.isEmpty ? "Jebkurš laiks" : parts.joined(separator: " · ")
    }
}

private struct AddFavoriteCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(0.25),
                        style: StrokeStyle(lineWidth: 3, dash: [10, 8])
                    )
                VStack(spacing: 14) {
                    Image(systemName: "plus")
                        .font(.system(size: 48, weight: .light))
                    Text("Pievienot favorītu")
                        .font(.system(size: 22, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.6))
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)

            Text(" ")
                .font(.system(size: 26))
                .frame(height: 26)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Match chooser

struct Chooser: Identifiable {
    let id = UUID()
    let favorite: Favorite
    let matches: [FavoriteMatch]
}

struct MatchChooserView: View {
    let chooser: Chooser
    let onSelect: (FavoriteMatch) -> Void

    var body: some View {
        ZStack {
            TVBackground()

            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(chooser.favorite.title)
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Vairāki raidījumi šodien — izvēlies, kuru skatīties")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.5))
                }

                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(chooser.matches) { match in
                            Button {
                                onSelect(match)
                            } label: {
                                HStack(spacing: 24) {
                                    Text(time(match.start))
                                        .font(.system(size: 24, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.5))
                                        .frame(width: 100, alignment: .leading)
                                    Text(match.title)
                                        .font(.system(size: 26, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(match.channel.title)
                                        .font(.system(size: 20))
                                        .foregroundStyle(.white.opacity(0.45))
                                    Image(systemName: "play.fill")
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                                .padding(.horizontal, 28)
                                .padding(.vertical, 18)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .scrollClipDisabled()
            }
            .padding(80)
        }
    }

    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "lv_LV")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

struct TVBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.08, blue: 0.16),
                Color(red: 0.01, green: 0.01, blue: 0.03),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(red: 0.94, green: 0.19, blue: 0.24))
                .frame(width: 14, height: 14)
            Text("TIEŠRAIDE")
                .font(.system(size: 17, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
        .background(.black.opacity(0.35), in: Capsule())
    }
}

#Preview {
    ChannelBrowserView()
}
