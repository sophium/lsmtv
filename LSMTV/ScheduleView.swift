import SwiftUI

struct ScheduleView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var path = NavigationPath()
    @State private var channel = LiveChannel.catalogue[0]
    @State private var dayOffset = 0
    @State private var entries: [GuideEntry] = []
    @State private var descriptions: [Int: String] = [:]
    @State private var isLoading = false
    @State private var scrollPosition: Int?

    private var day: Date {
        Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
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
                    } else if entries.isEmpty {
                        Spacer()
                        Text("Nav programmas informācijas.")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(entries) { entry in
                                    row(for: entry)
                                        .id(entry.id)
                                }
                            }
                            .scrollTargetLayout()
                            .padding(.vertical, 10)
                            .padding(.bottom, 80)
                        }
                        .scrollPosition(id: $scrollPosition, anchor: .center)
                        .onChange(of: entries) { _, newEntries in
                            focusCurrent(newEntries)
                        }
                        .onAppear {
                            focusCurrent(entries)
                        }
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
        .task(id: reloadToken) {
            await load()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                path = NavigationPath()
            }
        }
    }

    @ViewBuilder
    private func row(for entry: GuideEntry) -> some View {
        let programmeRow = ProgrammeRow(
            entry: entry,
            description: entry.startsAt.flatMap { descriptions[Self.minuteKey($0)] },
            isLive: entry.isOnNow,
            isPlayable: entry.isPlayableRecording
        )

        if let source = playbackSource(for: entry) {
            NavigationLink(value: PlaybackRoute(source)) {
                programmeRow
            }
            .buttonStyle(.card)
        } else {
            programmeRow
                .focusable()
                .hoverEffect(.highlight)
        }
    }

    private func playbackSource(for entry: GuideEntry) -> PlaybackSource? {
        if entry.isOnNow { return .live(channel) }
        if entry.media != nil { return .recording(entry) }
        return nil
    }

    private var reloadToken: String {
        "\(channel.id)-\(dayOffset)"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .firstTextBaseline) {
                Text("Programma")
                    .font(.system(size: 60, weight: .bold, design: .rounded))
                Spacer()
                Text(Self.dayFormatter.string(from: day))
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }

            HStack(spacing: 16) {
                ForEach(LiveChannel.catalogue) { item in
                    ChoiceButton(title: item.title, isSelected: item.id == channel.id) {
                        channel = item
                    }
                }

                Rectangle()
                    .fill(.white.opacity(0.15))
                    .frame(width: 2, height: 34)
                    .padding(.horizontal, 8)

                ChoiceButton(title: "Vakar", isSelected: dayOffset == -1) { dayOffset = -1 }
                ChoiceButton(title: "Šodien", isSelected: dayOffset == 0) { dayOffset = 0 }
                ChoiceButton(title: "Rīt", isSelected: dayOffset == 1) { dayOffset = 1 }
            }
            .focusSection()
        }
    }

    private func load() async {
        isLoading = true

        async let guideTask = ReplayService.shared.guide(channel: channel, day: day)
        async let epgTask = LSMService.shared.schedule(for: channel, day: day)

        let guide = (try? await guideTask) ?? []
        let epg = await epgTask

        var descriptionsByMinute: [Int: String] = [:]
        for programme in epg {
            guard let start = programme.since,
                  let text = programme.description,
                  !text.isEmpty else { continue }
            descriptionsByMinute[Self.minuteKey(start)] = text
        }
        descriptions = descriptionsByMinute

        if guide.isEmpty {
            entries = epg.map {
                GuideEntry(
                    id: $0.id,
                    title: $0.title,
                    startsAt: $0.since,
                    endsAt: $0.till,
                    isVOD: false,
                    channelExternalID: channel.externalID,
                    media: nil
                )
            }
        } else {
            entries = guide
        }

        isLoading = false
    }

    /// Opens today's schedule at the programme on air. Uses the scroll
    /// position binding rather than `scrollTo`, because the latter moves
    /// focus onto the target row and skips the channel/day buttons.
    private func focusCurrent(_ items: [GuideEntry]) {
        guard dayOffset == 0, !items.isEmpty else { return }
        let now = Date()
        let target = items.first { entry in
            guard let start = entry.startsAt, let end = entry.endsAt else { return false }
            return now >= start && now < end
        } ?? items.first { ($0.startsAt ?? .distantPast) > now }
            ?? items.last
        guard let target else { return }
        scrollPosition = target.id
    }

    private static func minuteKey(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 60)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "lv_LV")
        formatter.dateFormat = "EEEE, d. MMMM"
        return formatter
    }()
}

private struct ChoiceButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(isSelected ? Color.white : Color.white.opacity(0.18))
        .foregroundStyle(isSelected ? .black : .white)
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.06 : 1)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .accessibilityIdentifier("chip.\(title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ProgrammeRow: View {
    let entry: GuideEntry
    let description: String?
    let isLive: Bool
    let isPlayable: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 30) {
            Text(timeRange)
                .font(.system(size: 24, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 160, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text(entry.title)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 19))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 20)

            if isLive {
                LiveBadge()
            } else if isPlayable {
                HStack(spacing: 10) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 22))
                    Text("IERAKSTS")
                        .font(.system(size: 17, weight: .bold))
                        .tracking(1.2)
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.white.opacity(0.08), in: Capsule())
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(isLive ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
        )
    }

    private var timeRange: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "lv_LV")
        formatter.dateFormat = "HH:mm"
        let start = entry.startsAt.map(formatter.string(from:)) ?? "--:--"
        let end = entry.endsAt.map(formatter.string(from:)) ?? "--:--"
        return "\(start) – \(end)"
    }
}

#Preview {
    ScheduleView()
}
