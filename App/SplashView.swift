import SwiftUI
import AVKit

struct SplashView: View {
    @Binding var isFinished: Bool
    @State private var opacity: Double = 1.0
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayerView(player: player)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .opacity(opacity)
        .onAppear { setupAndPlay() }
    }

    private func setupAndPlay() {
        guard let url = Bundle.main.url(forResource: "DispatcharrSplash", withExtension: "mp4") else {
            isFinished = true
            return
        }
        let avPlayer = AVPlayer(url: url)
        avPlayer.isMuted = true
        player = avPlayer
        avPlayer.play()

        let duration = 3.6
        DispatchQueue.main.asyncAfter(deadline: .now() + duration - 0.5) {
            withAnimation(.easeOut(duration: 0.5)) { opacity = 0 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) {
            isFinished = true
        }
    }
}

struct VideoPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.configure(with: player)
        return view
    }
    func updateUIView(_ uiView: PlayerUIView, context: Context) {}
}

final class PlayerUIView: UIView {
    private var playerLayer: AVPlayerLayer?
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    func configure(with player: AVPlayer) {
        guard let layer = layer as? AVPlayerLayer else { return }
        layer.player = player
        layer.videoGravity = .resizeAspect   // ← was .resizeAspectFill; this shows full video
        self.playerLayer = layer
        backgroundColor = .black
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
    }
}
