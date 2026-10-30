import SwiftUI

struct ArchiveView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var path = NavigationPath()
    @State private var items: [ArchiveItem] = []
    @State private var category: String?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let columns = [
        GridItem(.fixed(400), spacing: 40),
        GridItem(.fixed(400), spacing: 40),
        GridItem(.fixed(400), spacing: 40),
        GridItem(.fixed(400), spacing: 40),
    ]

    private var categories: [String] {
        Array(Set(items.compactMap(\.category))).sorted()
    }

    private var visibleItems: [ArchiveItem] {
        guard let category else { return items }
        return items.filter { $0.category == category }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                TVBackground()

                VStack(alignment: .leading, spacing: 36) {
                    header

                    if isLoading {
                        Spacer()
                        ProgressView()
                            .scaleEffect(1.4)
                            .frame(maxWidth: .infinity)
                        Spacer()
                    } else if let errorMessage {
                        Spacer()
                        VStack(spacing: 20) {
                            Text(errorMessage)
                                .font(.system(size: 26))
                                .foregroundStyle(.white.opacity(0.6))
                            Button("Mēģināt vēlreiz") {
                                Task { await load() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 48) {
                                ForEach(visibleItems) { item in
                                    NavigationLink(value: PlaybackRoute(.archive(item))) {
                                        ArchiveCard(item: item)
                                    }
                                    .buttonStyle(.card)
                                }
                            }
                            .padding(.bottom, 80)
                        }
                        .scrollClipDisabled()
                    }
                }
                .padding(.horizontal, 100)
                .padding(.top, 60)
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
            guard items.isEmpty else { return }
            await load()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                path = NavigationPath()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                Text("Arhīvs")
                    .font(.system(size: 60, weight: .bold, design: .rounded))
                Spacer()
                Text("\(visibleItems.count) ieraksti")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.45))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    FilterChip(title: "Visi", isSelected: category == nil) {
                        category = nil
                    }
                    ForEach(categories, id: \.self) { name in
                        FilterChip(title: name, isSelected: category == name) {
                            category = name
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollClipDisabled()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            items = try await LSMService.shared.archive()
        } catch {
            errorMessage = "Arhīvu neizdevās ielādēt. \(error.localizedDescription)"
        }
        isLoading = false
    }
}

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    Capsule().fill(isSelected ? Color.white.opacity(0.9) : Color.white.opacity(0.1))
                )
                .foregroundStyle(isSelected ? .black : .white)
        }
        .buttonStyle(.plain)
    }
}

private struct ArchiveCard: View {
    let item: ArchiveItem

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.07))

                if let imageURL = item.imageURL {
                    AsyncImage(url: imageURL) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .scaledToFill()
                        } else {
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .frame(width: 400, height: 225)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 19))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
        .frame(width: 400, alignment: .leading)
    }

    private var subtitle: String {
        [item.category, item.year].compactMap { $0 }.joined(separator: " · ")
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.12, green: 0.18, blue: 0.35), Color(red: 0.04, green: 0.05, blue: 0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "film")
                .font(.system(size: 60, weight: .light))
                .foregroundStyle(.white.opacity(0.25))
        }
    }
}

#Preview {
    ArchiveView()
}
