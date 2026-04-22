import SwiftUI

/// Dumb presentation primitive: given an ordered tile list and a
/// `content` closure that renders one tile, lay them out per
/// `MultiviewGridMath`'s rect table inside a `GeometryReader`-sized
/// container with animated transitions for add/remove/rearrange.
///
/// Responsibilities:
/// - Compute rects for the current tile count + container size.
/// - Render each tile with `.frame(width:height:).position(x:y:)`.
/// - Animate `tiles` changes with a single `.animation(...) value:
///   tiles` on the container.
/// - Apply `.transition(.scale.combined(with: .opacity))` on each tile
///   so additions/removals pop rather than jumping.
///
/// Non-responsibilities (kept out so the layout stays reusable):
/// - Focus / press handling (tile wrapper).
/// - Tap-to-take-audio / per-tile menu (tile wrapper).
/// - Drag-and-drop for rearrange (container view).
/// - Fullscreen-within-grid promotion (container view).
///
/// The caller passes a `content: (MultiviewTile) -> Content` closure
/// that's invoked for each tile. Typically this will be the
/// `MultiviewTileView` wrapper from Phase 3, but the preview below
/// exercises it with colored swatches to verify rect shape.
struct MultiviewLayoutView<Content: View>: View {
    let tiles: [MultiviewTile]
    let spacing: CGFloat
    @ViewBuilder var content: (MultiviewTile) -> Content

    init(
        tiles: [MultiviewTile],
        spacing: CGFloat = MultiviewGridMath.defaultSpacing,
        @ViewBuilder content: @escaping (MultiviewTile) -> Content
    ) {
        self.tiles = tiles
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        GeometryReader { geom in
            if tiles.count == 1, let sole = tiles.first {
                // N=1 short-circuit — critical for auto-PiP restore.
                //
                // At N=1 the sole tile IS the player view. Wrapping it
                // in `.frame(width:height:).position(x:y:)` inside an
                // `.animation(.easeInOut, value: tiles)` scope inserts
                // a transform + implicit-animation layer above the
                // `AVSampleBufferDisplayLayer`, which makes iOS's
                // auto-PiP restore animation unable to compute a
                // clean target rect and fall back to its default
                // "zoom + PiP-icon placeholder" transition. Legacy
                // `PlayerView` mounts the representable flat inside a
                // plain ZStack (no position/frame/animation wrapper)
                // and iOS's restore lands cleanly there — we match
                // that shape at N=1.
                //
                // At N>=2 the grid math (position + frame + implicit
                // tiles-value animation) is exactly what we want for
                // the add/remove/rearrange choreography, so we keep
                // it there.
                content(sole)
                    .frame(width: geom.size.width, height: geom.size.height)
            } else {
                let rects = MultiviewGridMath.rects(
                    for: tiles.count,
                    in: geom.size,
                    spacing: spacing
                )
                ZStack(alignment: .topLeading) {
                    // Zip is safe: if tiles.count > 9 the math clamps to 9
                    // and zip will truncate — we'd rather drop a tile
                    // visually than index-OOB crash. The store itself caps
                    // at 9 via `MultiviewStore.maxTiles`.
                    ForEach(Array(zip(tiles, rects).enumerated()), id: \.element.0.id) { _, pair in
                        let (tile, rect) = pair
                        content(tile)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.28), value: tiles)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
/// Preview scaffolding — cycles tile count 1→9 with colored swatches
/// so the rect table can be eyeballed without wiring MPVPlayerView.
private struct MultiviewLayoutPreviewHost: View {
    @State private var count: Int = 1

    private static let palette: [Color] = [
        .red, .orange, .yellow, .green, .mint,
        .teal, .cyan, .blue, .indigo, .purple
    ]

    private var tiles: [MultiviewTile] {
        (0..<count).map { i in
            let url = URL(string: "https://example.com/\(i).m3u8")!
            let dummyItem = ChannelDisplayItem(
                id: "preview-\(i)",
                name: "Tile \(i + 1)",
                number: "\(i + 1)",
                logoURL: nil,
                group: "Preview",
                categoryOrder: 0,
                streamURL: url,
                streamURLs: [url]
            )
            return MultiviewTile(
                id: "preview-\(i)",
                item: dummyItem,
                streamURL: url,
                headers: [:],
                addedAt: Date()
            )
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            MultiviewLayoutView(tiles: tiles) { tile in
                let idx = Int(tile.id.dropFirst("preview-".count)) ?? 0
                ZStack {
                    Rectangle()
                        .fill(Self.palette[idx % Self.palette.count].opacity(0.85))
                    Text("\(idx + 1)")
                        .font(.system(size: 60, weight: .heavy))
                        .foregroundColor(.white)
                }
                .cornerRadius(8)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .padding(20)

            HStack {
                Button("−") { if count > 1 { count -= 1 } }
                    .disabled(count <= 1)
                Text("N = \(count)")
                    .font(.headline.monospacedDigit())
                    .frame(width: 80)
                Button("+") { if count < 9 { count += 1 } }
                    .disabled(count >= 9)
            }
            .font(.title2)
            .padding(.bottom, 20)
        }
    }
}

#Preview("Multiview Layout 1→9") {
    MultiviewLayoutPreviewHost()
}
#endif
