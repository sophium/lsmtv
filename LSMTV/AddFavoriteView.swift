import SwiftUI

struct AddFavoriteView: View {
    let editing: Favorite?
    let onFinish: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = FavoritesStore.shared

    @State private var query: String

    @State private var candidates: [FavoriteResolver.SearchCandidate] = []
    @State private var isSearching = false

    @State private var pendingCandidate: FavoriteResolver.SearchCandidate?
    @State private var pickerMatch: FavoriteMatch?
    @State private var pickedImage: UIImage?
    @State private var currentPoster: UIImage?
    @State private var saveFailed = false

    init(editing: Favorite? = nil, onFinish: (() -> Void)? = nil) {
        self.editing = editing
        self.onFinish = onFinish
        _query = State(initialValue: editing?.query ?? DebugHooks.string("favoriteQuery") ?? "")
    }

    private func finish() {
        if let onFinish {
            onFinish()
        } else {
            dismiss()
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            TVBackground()

            if let editing {
                editScreen(editing)
            } else {
                searchScreen
            }
        }
        .task(id: searchKey) {
            guard editing == nil, !trimmedQuery.isEmpty else {
                candidates = []
                return
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await search()

            if DebugHooks.consume("favoriteFrameDemo"),
               pickerMatch == nil,
               let first = candidates.first {
                beginPicking(first)
            }
        }
        .task {
            guard let editing else { return }
            currentPoster = store.image(for: editing)
        }
        .fullScreenCover(item: $pickerMatch) { match in
            FramePickerView(
                channel: match.channel,
                start: match.start,
                end: match.end
            ) { image in
                handlePicked(image)
            } onCancel: {
                pickerMatch = nil
                pendingCandidate = nil
            }
        }
    }

    private var searchKey: String {
        query
    }

    // MARK: - Search

    private var searchScreen: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("Pievienot favorītu")
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            TextField("Raidījuma nosaukums, piem. Panorāma vai sports", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 26))
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(.white)

            HStack(spacing: 24) {
                if !trimmedQuery.isEmpty {
                    Button("Pievienot “\(trimmedQuery)”") {
                        saveQueryFavorite()
                    }
                    .buttonStyle(.borderedProminent)
                }

                if isSearching {
                    ProgressView()
                } else if !candidates.isEmpty {
                    Text("\(candidates.count) raidījumi")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            if candidates.isEmpty && !isSearching && !trimmedQuery.isEmpty {
                Text("Nekas neatrasts. Mēģini īsāku meklējamo tekstu.")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.45))
            }

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(candidates) { candidate in
                        Button {
                            beginPicking(candidate)
                        } label: {
                            candidateRow(candidate)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.vertical, 8)
                .padding(.bottom, 60)
            }
            .scrollClipDisabled()
        }
        .padding(.horizontal, 100)
        .padding(.top, 70)
    }

    private func candidateRow(_ candidate: FavoriteResolver.SearchCandidate) -> some View {
        HStack(spacing: 24) {
            Text(Self.timeFormatter.string(from: candidate.exampleStart))
                .font(.system(size: 24, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 110, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(candidate.channel.title)
                    .font(.system(size: 19))
                    .foregroundStyle(.white.opacity(0.45))
            }

            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Picking a frame

    private func beginPicking(_ candidate: FavoriteResolver.SearchCandidate) {
        Task {
            if let occurrence = await FavoriteResolver.latestPastOccurrence(
                title: candidate.title,
                channel: candidate.channel
            ) {
                pendingCandidate = candidate
                pickerMatch = occurrence
            } else {
                saveCandidate(candidate, image: nil)
                finish()
            }
        }
    }

    private func handlePicked(_ image: UIImage) {
        if let candidate = pendingCandidate {
            guard saveCandidate(candidate, image: image) else {
                pendingCandidate = nil
                pickerMatch = nil
                return
            }
            pendingCandidate = nil
            pickerMatch = nil
            finish()
        } else {
            pickedImage = image
            pickerMatch = nil
        }
    }

    private func chooseEditFrame(_ editing: Favorite) {
        Task {
            if let occurrence = await FavoriteResolver.posterSource(for: editing) {
                pendingCandidate = nil
                pickerMatch = occurrence
            }
        }
    }

    // MARK: - Edit

    private func editScreen(_ editing: Favorite) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Labot favorītu")
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 10) {
                Text("Nosaukums")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                TextField("Raidījuma nosaukums", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.white)
            }

            if let minutes = editing.startMinutes {
                Text("Sākuma laiks · " + String(format: "%02d:%02d", minutes / 60, minutes % 60))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("Attēls")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))

                HStack(spacing: 24) {
                    if let preview = pickedImage ?? currentPoster {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 240, height: 135)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button(pickedImage == nil && currentPoster == nil ? "Izvēlēties kadru" : "Mainīt attēlu") {
                        chooseEditFrame(editing)
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 24) {
                Button("Saglabāt") {
                    saveEdit(editing)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    store.remove(editing)
                    finish()
                } label: {
                    Text("Dzēst favorītu")
                }
                .buttonStyle(.bordered)

                Button("Atcelt") {
                    finish()
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 8)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 100)
        .padding(.top, 60)
    }

    private func saveEdit(_ editing: Favorite) {
        var favorite = editing
        let trimmed = trimmedQuery
        if !trimmed.isEmpty {
            if trimmed != favorite.query {
                favorite.title = trimmed
            }
            favorite.query = trimmed
        }

        if let pickedImage {
            guard let name = store.savePoster(pickedImage) else {
                saveFailed = true
                return
            }
            favorite.posterFileName = name
        }

        store.update(favorite)
        finish()
    }

    private func search() async {
        isSearching = true
        candidates = await FavoriteResolver.search(query: trimmedQuery, startMinutes: nil)
        isSearching = false
    }

    // MARK: - Saving

    @discardableResult
    private func saveCandidate(_ candidate: FavoriteResolver.SearchCandidate, image: UIImage?) -> Bool {
        var favorite = Favorite(
            id: UUID(),
            title: candidate.title,
            query: candidate.title,
            startMinutes: candidate.startMinutes,
            channelExternalID: candidate.channel.externalID,
            posterFileName: nil,
            createdAt: Date()
        )
        if let image {
            guard let name = store.savePoster(image) else {
                saveFailed = true
                return false
            }
            favorite.posterFileName = name
        }
        store.add(favorite)
        return true
    }

    private func saveQueryFavorite() {
        let favorite = Favorite(
            id: UUID(),
            title: trimmedQuery,
            query: trimmedQuery,
            startMinutes: nil,
            channelExternalID: nil,
            posterFileName: nil,
            createdAt: Date()
        )
        store.add(favorite)
        finish()
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "lv_LV")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
