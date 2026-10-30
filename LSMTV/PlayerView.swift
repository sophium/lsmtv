import AVKit
import SwiftUI

struct PlayerView: View {
    let source: PlaybackSource
    let favorite: Favorite?
    /// Explicit pop supplied by the hosting NavigationStack.
    let onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    @StateObject private var model = PlaybackModel()
    @State private var activeSource: PlaybackSource
    @State private var editingFavorite: Favorite?
    @State private var isClosing = false
    @State private var showGuide = false

    init(source: PlaybackSource, favorite: Favorite? = nil, onClose: (() -> Void)? = nil) {
        self.source = source
        self.favorite = favorite
        self.onClose = onClose
        _model = StateObject(wrappedValue: PlaybackModel())
        _activeSource = State(initialValue: source)
    }

    /// The instant the guide should open on: the start of what is playing.
    private var guideFocusDate: Date? {
        switch activeSource {
        case .liveWindow(_, let from, _):
            return from
        case .live:
            return Date()
        case .recording(let entry):
            return entry.startsAt ?? Date()
        case .archive:
            return nil
        }
    }

    private var playerChannel: LiveChannel {
        switch activeSource {
        case .live(let channel), .liveWindow(let channel, _, _):
            return channel
        case .recording(let entry):
            return entry.channel ?? LiveChannel.catalogue[0]
        case .archive:
            return LiveChannel.catalogue[0]
        }
    }

    private func play(_ source: PlaybackSource) {
        activeSource = source
        isClosing = false
        Task { await model.start(source) }
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch model.phase {
            case .loading:
                loading
            case .playing:
                PlayerSurface(
                    player: model.player,
                    isLive: model.isLive,
                    onEditFavorite: favorite.map { fav in
                        {
                            editingFavorite = FavoritesStore.shared.favorites
                                .first { $0.id == fav.id } ?? fav
                        }
                    },
                    onMenu: { close() },
                    onShowGuide: { showGuide = true },
                    menuEnabled: !showGuide && editingFavorite == nil
                )
                .ignoresSafeArea()
            case .failed(let message):
                failure(message)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .onExitCommand {
            close()
        }
        .task {
            await model.start(activeSource)
        }
        .task {
            if DebugHooks.consume("openGuide") {
                showGuide = true
            }
        }
        .task {
            guard let raw = DebugHooks.consumeString("autoCloseSeconds"),
                  let seconds = Double(raw) else { return }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            close()
        }
        .onDisappear {
            model.stop()
        }
        .sheet(item: $editingFavorite) { favorite in
            AddFavoriteView(editing: favorite, onFinish: { editingFavorite = nil })
        }
        .sheet(isPresented: $showGuide) {
            PlayerGuideView(channel: playerChannel, focusDate: guideFocusDate) { selected in
                showGuide = false
                play(selected)
            }
        }
    }

    private var loading: some View {
        VStack(spacing: 32) {
            ProgressView()
                .scaleEffect(1.6)
            Text(activeSource.title)
                .font(.system(size: 46, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
            Text("Ielādē…")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(80)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 28) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 72))
                .foregroundStyle(.white.opacity(0.4))
            Text("Neizdevās atskaņot")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
            Text(message)
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.5))
            Button("Mēģināt vēlreiz") {
                Task { await model.start(source) }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .padding(80)
    }
}

@MainActor
final class PlaybackModel: ObservableObject {
    enum Phase {
        case loading
        case playing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var isLive = false
    let player = AVPlayer()

    private var keyLoader: FairPlayKeyLoader?
    private var statusObservation: NSKeyValueObservation?

    func start(_ source: PlaybackSource) async {
        phase = .loading
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
        keyLoader = nil

        do {
            var startsAtBeginning = false
            let descriptor: PlaybackDescriptor
            switch source {
            case .live(let channel):
                // Open at the live edge, but with the current programme as a
                // seekable window so "Sākt no sākuma" works.
                let programme = await LSMService.shared.nowPlaying(for: channel)
                descriptor = try await LSMService.shared.livePlayback(for: channel, from: programme?.since)
            case .liveWindow(let channel, let from, let to):
                descriptor = try await LSMService.shared.livePlayback(for: channel, from: from, to: to)
                startsAtBeginning = true
            case .archive(let item):
                descriptor = try await LSMService.shared.archivePlayback(for: item)
            case .recording(let entry):
                guard let media = entry.media else { throw ReplayError.noPlayback }
                let assetID = try await ReplayService.shared.playbackAssetID(for: media)
                descriptor = try await LSMService.shared.recordingPlayback(assetID: assetID)
            }

            let asset = AVURLAsset(url: descriptor.url)
            isLive = descriptor.isLive
            if let fairPlay = descriptor.fairPlay {
                let loader = FairPlayKeyLoader(
                    certificateURL: fairPlay.certificateURL,
                    licenseURL: fairPlay.licenseURL
                )
                loader.attach(to: asset)
                keyLoader = loader
            }

            let item = AVPlayerItem(asset: asset)
            if descriptor.isLive {
                item.preferredForwardBufferDuration = 3
            }

            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                switch item.status {
                case .failed:
                    let reason = item.error?.localizedDescription ?? "The stream stopped."
                    Task { @MainActor [weak self] in
                        self?.phase = .failed(reason)
                    }
                case .readyToPlay where startsAtBeginning:
                    Task { @MainActor [weak self] in
                        self?.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                default:
                    break
                }
            }

            player.replaceCurrentItem(with: item)
            player.play()
            phase = .playing
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
        keyLoader = nil
    }
}

/// The native tvOS player: transport bar, Info panel, audio-track picker,
/// plus a "Sākt no sākuma" action that works for live and on-demand alike.
/// AVPlayerViewController otherwise lets the Menu press fall through to tvOS,
/// which sends the whole app to the Home screen instead of going back.
private final class MenuInterceptingPlayerViewController: AVPlayerViewController {
    var onMenu: (() -> Void)?

    /// Disabled while a sheet (guide/editor) is on top, so Menu closes that.
    var isMenuGestureEnabled = true {
        didSet { menuPress?.isEnabled = isMenuGestureEnabled }
    }

    private var menuPress: UITapGestureRecognizer?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installMenuGesture()
    }

    override func viewWillDisappear(_ animated: Bool) {
        removeMenuGesture()
        super.viewWillDisappear(animated)
    }

    /// A window-level press recognizer is the only place the Menu event is
    /// reliably seen: AVKit consumes it inside the player's own views.
    private func installMenuGesture() {
        guard menuPress == nil, let window = view.window else { return }
        let gesture = UITapGestureRecognizer(target: self, action: #selector(handleMenuPress))
        gesture.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        window.addGestureRecognizer(gesture)
        menuPress = gesture
    }

    private func removeMenuGesture() {
        if let menuPress {
            menuPress.view?.removeGestureRecognizer(menuPress)
        }
        menuPress = nil
    }

    @objc private func handleMenuPress() {
        onMenu?()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            onMenu?()
            return
        }
        super.pressesBegan(presses, with: event)
    }
}

struct PlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    let isLive: Bool
    let onEditFavorite: (() -> Void)?
    let onMenu: () -> Void
    let onShowGuide: (() -> Void)?
    let menuEnabled: Bool

    final class Coordinator: NSObject {
        var onEditFavorite: (() -> Void)?
        var onMenu: (() -> Void)?
        var onShowGuide: (() -> Void)?

        @objc func handleMenu() {
            onMenu?()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = MenuInterceptingPlayerViewController()
        controller.isMenuGestureEnabled = true
        controller.player = player
        controller.showsPlaybackControls = true
        controller.view.backgroundColor = .black
        controller.onMenu = onMenu
        context.coordinator.onEditFavorite = onEditFavorite
        context.coordinator.onMenu = onMenu
        context.coordinator.onShowGuide = onShowGuide

        var menuItems: [UIMenuElement] = [
            UIAction(
                title: "Sākt no sākuma",
                image: UIImage(systemName: "backward.end.fill")
            ) { [weak player] _ in
                player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            },
        ]

        if isLive {
            menuItems.append(
                UIAction(
                    title: "Tiešraide",
                    image: UIImage(systemName: "dot.radiowaves.left.and.right")
                ) { [weak player] _ in
                    guard let item = player?.currentItem,
                          let range = item.seekableTimeRanges.last?.timeRangeValue else { return }
                    let end = CMTimeAdd(range.start, range.duration)
                    let target = CMTimeSubtract(end, CMTime(seconds: 1, preferredTimescale: 600))
                    player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            )
        }

        if onShowGuide != nil {
            menuItems.append(
                UIAction(
                    title: "Programma",
                    image: UIImage(systemName: "list.bullet")
                ) { [weak coordinator = context.coordinator] _ in
                    coordinator?.onShowGuide?()
                }
            )
        }

        if onEditFavorite != nil {
            menuItems.append(
                UIAction(
                    title: "Labot favorītu",
                    image: UIImage(systemName: "star.fill")
                ) { [weak coordinator = context.coordinator] _ in
                    coordinator?.onEditFavorite?()
                }
            )
        }

        menuItems.append(
            UIAction(
                title: "Atpakaļ",
                image: UIImage(systemName: "chevron.backward")
            ) { [weak coordinator = context.coordinator] _ in
                coordinator?.onMenu?()
            }
        )

        controller.transportBarCustomMenuItems = menuItems
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.onEditFavorite = onEditFavorite
        context.coordinator.onMenu = onMenu
        context.coordinator.onShowGuide = onShowGuide
        if let playerController = controller as? MenuInterceptingPlayerViewController {
            playerController.onMenu = onMenu
            playerController.isMenuGestureEnabled = menuEnabled
        }
        if controller.player !== player {
            controller.player = player
        }
    }
}

#Preview {
    PlayerView(source: .live(LiveChannel.catalogue[0]))
}
