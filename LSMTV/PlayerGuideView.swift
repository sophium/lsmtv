import SwiftUI

/// The schedule, presented over the player. Selecting an entry switches what
/// is playing without leaving the player.
struct PlayerGuideView: View {
    let initialChannel: LiveChannel
    /// The programme being played — the list opens on it and marks it.
    let focusDate: Date?
    let onSelect: (PlaybackSource) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var channel: LiveChannel
    @State private var dayOffset = 0
    @State private var entries: [Programme] = []
    @State private var isLoading = true
    @State private var scrollPosition: Int?

    init(channel: LiveChannel, focusDate: Date?, onSelect: @escaping (PlaybackSource) -> Void) {
        self.initialChannel = channel
        self.focusDate = focusDate
        self.onSelect = onSelect
        _channel = State(initialValue: channel)
    }

    private var day: Date {
        Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
    }

    var body: some View {
        ZStack {
            TVBackground()

            VStack(alignment: .leading, spacing: 28) {
                header

                if isLoading {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.4)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else if entries.isEmpty {
                    Spacer()
                    Text("Nav programmas informācijas.")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(entries) { programme in
                                Button {
                                    select(programme)
                                } label: {
                                    row(programme)
                                }
                                .buttonStyle(.card)
                                .id(programme.id)
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.vertical, 8)
                        .padding(.bottom, 60)
                    }
                    .scrollClipDisabled()
                    .scrollPosition(id: $scrollPosition, anchor: .center)
                    .onAppear {
                        focusCurrent(entries)
                    }
                    .onChange(of: entries) { _, newEntries in
                        focusCurrent(newEntries)
                    }
                }
            }
            .padding(.horizontal, 90)
            .padding(.top, 50)
        }
        .task(id: reloadToken) {
            await load()
        }
    }

    private var reloadToken: String {
        "\(channel.id)-\(dayOffset)"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("Programma")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Button("Aizvērt") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 14) {
                ForEach(LiveChannel.catalogue) { item in
                    Chip(title: item.title, selected: item.id == channel.id) {
                        channel = item
                    }
                }

                Rectangle()
                    .fill(.white.opacity(0.15))
                    .frame(width: 2, height: 30)
                    .padding(.horizontal, 6)

                Chip(title: "Vakar", selected: dayOffset == -1) { dayOffset = -1 }
                Chip(title: "Šodien", selected: dayOffset == 0) { dayOffset = 0 }
                Chip(title: "Rīt", selected: dayOffset == 1) { dayOffset = 1 }
            }
            .focusSection()
        }
    }



    private func row(_ programme: Programme) -> some View {
        HStack(spacing: 24) {
            Text(timeRange(programme))
                .font(.system(size: 21, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 140, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(programme.title)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let description = programme.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 16)

            if isPlaying(programme) {
                Text("SKATĀS")
                    .font(.system(size: 15, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white, in: Capsule())
            } else if isOnNow(programme) {
                LiveBadge()
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isPlaying(programme) || isOnNow(programme) ? Color.white.opacity(0.14) : Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isPlaying(programme) ? Color.white.opacity(0.7) : Color.clear, lineWidth: 2)
        )
        .padding(.horizontal, 4)
    }

    private struct Chip: View {
        let title: String
        let selected: Bool
        let action: () -> Void

        @FocusState private var isFocused: Bool

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 21, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(selected ? Color.white : Color.white.opacity(0.18))
            .foregroundStyle(selected ? .black : .white)
            .focused($isFocused)
            .scaleEffect(isFocused ? 1.06 : 1)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            .accessibilityIdentifier("chip.\(title)")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    private func isPlaying(_ programme: Programme) -> Bool {
        guard let focusDate, let start = programme.since, let end = programme.till else { return false }
        return (focusDate >= start && focusDate < end) || abs(start.timeIntervalSince(focusDate)) < 60
    }

    private func isOnNow(_ programme: Programme) -> Bool {
        guard let start = programme.since, let end = programme.till else { return false }
        let now = Date()
        return now >= start && now < end
    }

    private func focusCurrent(_ items: [Programme]) {
        guard !items.isEmpty else { return }
        let focus = focusDate ?? Date()
        let target = items.first { isPlaying($0) } ?? items.first { ($0.since ?? .distantPast) > focus } ?? items.last
        guard let target else { return }
        scrollPosition = target.id
    }

    private func select(_ programme: Programme) {
        guard let start = programme.since, let end = programme.till else { return }
        let now = Date()
        let source: PlaybackSource
        if now < start {
            source = .live(channel)
        } else if now < end {
            source = .liveWindow(channel, from: start, to: nil)
        } else {
            source = .liveWindow(channel, from: start, to: end)
        }
        onSelect(source)
    }

    private func load() async {
        isLoading = true
        entries = await LSMService.shared.schedule(for: channel, day: day)
        isLoading = false
    }

    private func timeRange(_ programme: Programme) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "lv_LV")
        formatter.dateFormat = "HH:mm"
        let start = programme.since.map(formatter.string(from:)) ?? "--:--"
        let end = programme.till.map(formatter.string(from:)) ?? "--:--"
        return "\(start) – \(end)"
    }
}
