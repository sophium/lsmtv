import AVFoundation
import SwiftUI

/// A scrubbable 20-second clip around the programme start (−10s … +10s).
/// Left/right on the remote steps through it a frame at a time and Select
/// picks the frame currently on screen as the logo.
struct FramePickerView: View {
    let channel: LiveChannel
    let start: Date
    let end: Date
    let onPick: (UIImage) -> Void
    let onCancel: () -> Void

    @StateObject private var model = FramePickerModel()
    @FocusState private var scrubFocused: Bool
    @State private var captureFailed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    PlayerLayerView(player: model.player)
                    scrubSurface

                    Text("⬅ ➡ 0,5 s · diapazons −10s … +2min · Select izvēlas")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.5), in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 24)
                        .allowsHitTesting(false)

                    if !model.isReady {
                        ProgressView()
                            .scaleEffect(1.5)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                controls
                    .padding(.bottom, 44)
                    .padding(.top, 8)
            }
        }
        .task {
            await model.load(channel: channel, start: start, end: end)
            scrubFocused = true
            if DebugHooks.consume("autoPick") {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                pick()
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            Text(model.offsetLabel)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)

            HStack(spacing: 14) {
                Button("◀ 10s") {
                    Task { await model.step(by: -10) }
                }
                .buttonStyle(.bordered)

                Button("◀ 0,5s") {
                    Task { await model.step(by: -0.5) }
                }
                .buttonStyle(.bordered)

                Button("Izvēlies kadru") {
                    pick()
                }
                .buttonStyle(.borderedProminent)

                Button("0,5s ▶") {
                    Task { await model.step(by: 0.5) }
                }
                .buttonStyle(.bordered)

                Button("10s ▶") {
                    Task { await model.step(by: 10) }
                }
                .buttonStyle(.bordered)

                Button("Atpakaļ") {
                    onCancel()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var scrubSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .focusable(true)
            .focused($scrubFocused)
            .onMoveCommand { direction in
                switch direction {
                case .left:
                    Task { await model.step(by: -0.5) }
                case .right:
                    Task { await model.step(by: 0.5) }
                default:
                    break
                }
            }
            .onTapGesture {
                pick()
            }
            .overlay(
                Rectangle()
                    .strokeBorder(
                        scrubFocused ? Color.white.opacity(0.35) : Color.clear,
                        lineWidth: 4
                    )
                    .padding(24)
                    .allowsHitTesting(false)
            )
    }

    private func pick() {
        Task {
            if let image = await model.captureFrame() {
                onPick(image)
            } else {
                captureFailed = true
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                captureFailed = false
            }
        }
    }
}

@MainActor
final class FramePickerModel: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var isReady = false
    @Published private(set) var offsetLabel = ""

    private var output: AVPlayerItemVideoOutput?

    func load(channel: LiveChannel, start: Date, end: Date) async {
        let from = start.addingTimeInterval(-10)
        let to = start.addingTimeInterval(120)
        guard let descriptor = try? await LSMService.shared.livePlayback(
            for: channel,
            from: from,
            to: to
        ) else { return }

        let item = AVPlayerItem(url: descriptor.url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        self.output = output

        player.isMuted = true
        player.replaceCurrentItem(with: item)

        for _ in 0..<80 {
            if item.status == .readyToPlay { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        // Prime the buffer, then sit on the programme start (10s into the clip).
        player.playImmediately(atRate: 2)
        for _ in 0..<120 {
            if player.currentTime().seconds >= 10.2 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        player.pause()
        await seek(to: 10)
        isReady = true
    }

    func step(by delta: Double) async {
        let current = player.currentTime().seconds
        let target = min(max(current + delta, 0), 130)
        await seek(to: target)
    }

    private func seek(to seconds: Double) async {
        _ = await player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        offsetLabel = Self.label(for: seconds - 10)
    }

    /// Copies the frame currently on screen. A paused decoder may hold no
    /// pixel buffer, so nudge playback briefly and fall back to an image
    /// generator on the asset if the video output stays empty.
    func captureFrame() async -> UIImage? {
        guard let output, let item = player.currentItem else {
            print("[LSMTV] capture: no output/item")
            return nil
        }
        let target = player.currentTime()

        player.playImmediately(atRate: 1)
        try? await Task.sleep(nanoseconds: 180_000_000)
        player.pause()
        _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)

        for _ in 0..<20 {
            let time = player.currentTime()
            if output.hasNewPixelBuffer(forItemTime: time),
               let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
               let image = Self.image(from: buffer) {
                return image
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        do {
            let result = try await generator.image(at: target)
            let image = UIImage(cgImage: result.image)
            print("[LSMTV] capture: generator frame at \(result.actualTime.seconds) size=\(image.size)")
            return image
        } catch {
            print("[LSMTV] capture: generator failed \(error)")
        }
        return nil
    }

    private static func image(from buffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = CIContext().createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private static func label(for offset: Double) -> String {
        let rounded = (offset * 10).rounded() / 10
        let sign = rounded < 0 ? "−" : "+"
        let value = String(format: "%.1f", abs(rounded)).replacingOccurrences(of: ".", with: ",")
        return "\(sign)\(value)s"
    }
}

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerLayerUIView, context: Context) {
        view.playerLayer.player = player
    }
}

private final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
