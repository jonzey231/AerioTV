import CoreGraphics

/// Issue #48: user-selectable multiview grid "shape" for a given tile count.
/// Picked live from the player Options panel and persisted globally (one
/// preference for all counts) in `@AppStorage`. `MultiviewGridMath.rects(for:
/// count:in:spacing:)` maps each mode to the concrete rect table, falling back
/// to `.auto` whenever a mode does not apply to the current count. `.auto` is
/// the historical per-count default (layout1...layout9), so an existing user
/// who never opens the picker sees no change.
///
/// Inlined here (rather than its own file) because the project uses explicit
/// target membership; this keeps the new type compiled without a pbxproj edit.
enum MultiviewLayoutMode: String, CaseIterable, Identifiable, Sendable {
    /// The built-in default layout for the current count (layout1...layout9).
    case auto
    /// Balanced equal-size grid, landscape-preferred, last partial row
    /// centered. Only differs from `.auto` for counts whose default is
    /// asymmetric (3 and 5).
    case evenGrid
    /// One large hero tile on the left with the rest stacked on the right.
    /// Generalizes to any count >= 2. The hero is the per-tile spotlight
    /// selection if set, otherwise the first tile.
    case spotlight
    /// 6 only: the 5-tile "hero + 4 followers" layout with the normally
    /// empty bottom-right cell filled by the 6th tile (issue #48). Falls back
    /// to `.auto` at any other count.
    case heroCorner

    var id: String { rawValue }

    /// Persisted key shared by the store binding and the picker.
    static let storageKey = "multiviewLayoutMode"

    var displayName: String {
        switch self {
        case .auto:       return "Default"
        case .evenGrid:   return "Even Grid"
        case .spotlight:  return "Spotlight"
        case .heroCorner: return "Hero + Corner"
        }
    }

    /// SF Symbol for the picker row.
    var symbolName: String {
        switch self {
        case .auto:       return "square.grid.2x2"
        case .evenGrid:   return "rectangle.grid.2x2"
        case .spotlight:  return "rectangle.lefthalf.inset.filled"
        case .heroCorner: return "rectangle.grid.1x2"
        }
    }

    /// The modes worth offering at a given tile count, with duplicates of
    /// `.auto` omitted (for 4/6/7/8/9 the default already IS an even grid).
    /// Returns `[]` for counts with no real choice (<= 1) so the picker hides.
    static func available(forTileCount n: Int) -> [MultiviewLayoutMode] {
        switch n {
        case ..<2:  return []
        case 2:     return [.auto, .spotlight]
        case 3:     return [.auto, .evenGrid]          // .auto (layout3) is already the spotlight shape
        case 4:     return [.auto, .spotlight]
        case 5:     return [.auto, .evenGrid, .spotlight]
        case 6:     return [.auto, .heroCorner, .spotlight]
        default:    return [.auto, .spotlight]          // 7, 8, 9
        }
    }
}

/// Pure math: tile-count + container-size + spacing → array of per-tile
/// rects, in the same order as `MultiviewStore.tiles`.
///
/// Why not SwiftUI's `Layout` protocol?
/// - Overkill for N ≤ 9 (the plan flagged this).
/// - `Layout` + tvOS focus-engine during animated rearrangement is a
///   known hazard zone; plain `ZStack { ForEach }` driven by
///   `.frame(width:height:).position(x:y:)` from this math avoids it.
/// - Being pure lets us unit-test rect shape for every N without a
///   UIKit host.
///
/// Layout table (0-indexed tile order = reading order: top-left first,
/// row-major):
///
/// | N | Shape                                                  |
/// |---|--------------------------------------------------------|
/// | 1 | Full container                                         |
/// | 2 | 2×1 horizontal split (landscape priority)              |
/// | 3 | Big left (2/3 wide, full height) + 2 stacked on right  |
/// | 4 | 2×2                                                    |
/// | 5 | Big top-left (2×2 of a 3×3) + 4 small (corners filled) |
/// | 6 | 3×2                                                    |
/// | 7 | 3×3 with bottom corners empty (bottom-center centered) |
/// | 8 | 3×3 with bottom-center gap                             |
/// | 9 | 3×3                                                    |
///
/// The table above describes a LANDSCAPE (or square) container. A container
/// taller than it is wide takes the portrait path instead: the hero shapes
/// transpose (big tile on top, followers underneath) and the uniform grids
/// re-shape to stack, so a 2-up splits top/bottom rather than left/right.
/// See "MARK: - Portrait". Rotation needs no extra plumbing — the caller
/// (`MultiviewLayoutView`) already re-runs this math from a `GeometryReader`,
/// so a new container size picks the matching table on the spot.
///
/// All rects are computed against the container origin (0,0) and sized
/// so that adjacent rect edges are separated by `spacing`. Negative or
/// zero containers return an empty array (defensive — avoids NaN
/// propagation into SwiftUI).
enum MultiviewGridMath {

    /// Minimum sensible tile dimension. If the container is smaller
    /// than `3 × minTile + 2 × spacing` on either axis we still
    /// produce rects, but they may render tiny — the caller (the
    /// container view) is responsible for not presenting multiview at
    /// compact widths.
    static let minTileDimension: CGFloat = 80

    /// Default visual spacing between tiles. Zero gutter — tiles
    /// sit flush against each other so the grid reads as one
    /// continuous display surface rather than a tiled card collection.
    /// Per user request (2026-04-17): the previous 6pt gutter visually
    /// cluttered the grid and wasted screen real-estate on a TV.
    /// Focus feedback (scale + shadow) still lets the user pick out
    /// the focused tile without a physical gap.
    static let defaultSpacing: CGFloat = 0

    /// For a given tile index in a given count, return the index of
    /// the physical neighbor in the specified direction (or `nil`
    /// when the tile is at an edge).
    ///
    /// Used by tvOS relocate-mode to let the Siri Remote arrow keys
    /// swap the tile with its ACTUAL visual neighbor — not just the
    /// next entry in the list, which for N=5/7/8 breaks the user's
    /// mental model. The math cheats by querying the rect table: the
    /// neighbor in a direction is the tile whose centroid is closest
    /// along that axis AND overlaps on the perpendicular axis.
    ///
    /// - Parameters:
    ///   - index: current tile index
    ///   - count: total tile count
    ///   - direction: .left / .right / .up / .down (uses a string
    ///     enum below so we're SwiftUI-`MoveCommandDirection`-free
    ///     at this layer — the caller converts)
    /// - Returns: neighbor index if one exists in that direction
    enum NeighborDirection { case left, right, up, down }

    static func physicalNeighbor(
        of index: Int,
        count: Int,
        direction: NeighborDirection,
        container: CGSize = CGSize(width: 1920, height: 1080),
        spacing: CGFloat = defaultSpacing
    ) -> Int? {
        // Use a fixed reference container for topology — absolute
        // pixel sizes cancel out since we only compare relative
        // positions. 1920×1080 is arbitrary but matches a common
        // tvOS screen so the rect math produces well-shaped rects.
        let rects = Self.rects(for: count, in: container, spacing: spacing)
        guard rects.indices.contains(index) else { return nil }
        let me = rects[index]
        // Primary-axis tolerance: lets tiles separated by `spacing`
        // still register as "in the requested direction". With
        // `spacing=0` this is 1 px of subpixel slop, which is fine.
        let eps = spacing + 1

        // Perpendicular-axis overlap must be strictly POSITIVE — mere
        // boundary-point contact doesn't count. Without this, a 2×2
        // grid with `spacing=0` treats the top-right tile as a
        // right-neighbour of the bottom-left tile, because they share
        // the single point `(halfW, halfH)` and the old 1-px eps
        // pushed `y.maxY+eps > me.minY` over the line.
        //
        // Using `> 1` (instead of `> 0`) tolerates floating-point
        // rounding in layout math while still rejecting exact-
        // boundary contact — the "real" overlap between two tiles in
        // the same row is always > 1 px regardless of container size
        // (smallest case is a 9-grid third-height tile sharing its
        // full-height edge with a neighbour, which is hundreds of px).
        func perpendicularOverlap(on axis: (CGFloat, CGFloat), of r: (CGFloat, CGFloat)) -> CGFloat {
            min(axis.1, r.1) - max(axis.0, r.0)
        }

        // Candidates are tiles that overlap on the perpendicular axis
        // AND lie strictly on the requested side. Pick the closest.
        var best: (idx: Int, dist: CGFloat)?
        for (i, r) in rects.enumerated() where i != index {
            let xOverlap = perpendicularOverlap(on: (me.minX, me.maxX), of: (r.minX, r.maxX))
            let yOverlap = perpendicularOverlap(on: (me.minY, me.maxY), of: (r.minY, r.maxY))
            let overlapsX = xOverlap > 1
            let overlapsY = yOverlap > 1
            let d: CGFloat
            switch direction {
            case .left:
                guard r.maxX <= me.minX + eps, overlapsY else { continue }
                d = me.minX - r.maxX
            case .right:
                guard r.minX >= me.maxX - eps, overlapsY else { continue }
                d = r.minX - me.maxX
            case .up:
                guard r.maxY <= me.minY + eps, overlapsX else { continue }
                d = me.minY - r.maxY
            case .down:
                guard r.minY >= me.maxY - eps, overlapsX else { continue }
                d = r.minY - me.maxY
            }
            if best == nil || d < best!.dist {
                best = (i, d)
            }
        }
        return best?.idx
    }

    /// Compute the rect for each tile in reading order.
    ///
    /// - Parameters:
    ///   - count: number of tiles in the grid (0–9). Values above 9
    ///     are clamped to 9; negative values return empty.
    ///   - container: the size of the bounding rect in which the
    ///     tiles should be placed.
    ///   - spacing: gutter between tiles, both horizontal and
    ///     vertical. Defaults to `defaultSpacing`.
    /// - Returns: `count` rects, each in container-local coordinates.
    static func rects(
        for count: Int,
        in container: CGSize,
        spacing: CGFloat = defaultSpacing
    ) -> [CGRect] {
        guard count > 0,
              container.width > 0,
              container.height > 0 else { return [] }
        let n = min(count, 9)
        if isPortrait(container) { return portraitRects(for: n, in: container, spacing: spacing) }
        switch n {
        case 1: return layout1(container)
        case 2: return layout2(container, spacing: spacing)
        case 3: return layout3(container, spacing: spacing)
        case 4: return layout4(container, spacing: spacing)
        case 5: return layout5(container, spacing: spacing)
        case 6: return layout6(container, spacing: spacing)
        case 7: return layout7(container, spacing: spacing)
        case 8: return layout8(container, spacing: spacing)
        case 9: return layout9(container, spacing: spacing)
        default: return []
        }
    }

    /// Issue #27: spotlight layout. One large tile on the left (2/3 width,
    /// full height) with the remaining tiles stacked in the right-hand
    /// column. `rect[0]` is the big one; the caller places the spotlighted
    /// tile there and the rest in order. This generalizes `layout3` (which is
    /// exactly this shape at count == 3) to any tile count.
    static func spotlightRects(
        for count: Int,
        in container: CGSize,
        spacing: CGFloat = defaultSpacing
    ) -> [CGRect] {
        guard count > 0, container.width > 0, container.height > 0 else { return [] }
        let n = min(count, 9)
        if n == 1 { return layout1(container) }
        // Portrait: hero on TOP (full width, 2/3 height) with the followers
        // in a row beneath. The transpose keeps the hero at index 0 and the
        // followers in order, which is the contract `MultiviewLayoutView`
        // relies on when it assigns rect[0] to the spotlighted tile.
        if isPortrait(container) {
            return transposed(container) { spotlightRects(for: n, in: $0, spacing: spacing) }
        }
        let bigW = (container.width - spacing) * 2 / 3
        let smallW = container.width - bigW - spacing
        let smallCount = n - 1
        let smallH = (container.height - spacing * CGFloat(smallCount - 1)) / CGFloat(smallCount)
        var rects: [CGRect] = [CGRect(x: 0, y: 0, width: bigW, height: container.height)]
        for i in 0..<smallCount {
            let y = (smallH + spacing) * CGFloat(i)
            rects.append(CGRect(x: bigW + spacing, y: y, width: smallW, height: smallH))
        }
        return rects
    }

    // MARK: - Issue #48: layout-mode resolution

    /// Resolve rects for an explicit layout MODE. Falls back to the per-count
    /// default for any mode that does not apply to the current count.
    static func rects(
        for mode: MultiviewLayoutMode,
        count: Int,
        in container: CGSize,
        spacing: CGFloat = defaultSpacing
    ) -> [CGRect] {
        switch mode {
        case .auto:      return rects(for: count, in: container, spacing: spacing)
        case .evenGrid:  return evenGridRects(for: count, in: container, spacing: spacing)
        case .spotlight: return spotlightRects(for: count, in: container, spacing: spacing)
        case .heroCorner:
            return count == 6
                ? heroCornerRects(container, spacing: spacing)
                : rects(for: count, in: container, spacing: spacing)
        }
    }

    /// The 5-tile hero layout (`layout5`) with the normally-empty bottom-right
    /// (col 2, row 2) cell filled by a 6th small tile. Reading order:
    /// hero → (2,0) → (2,1) → (0,2) → (1,2) → (2,2).
    static func heroCornerRects(_ c: CGSize, spacing: CGFloat = defaultSpacing) -> [CGRect] {
        guard c.width > 0, c.height > 0 else { return [] }
        if isPortrait(c) { return transposed(c) { heroCornerRects($0, spacing: spacing) } }
        var rects = layout5(c, spacing: spacing)
        let cellW = (c.width  - 2 * spacing) / 3
        let cellH = (c.height - 2 * spacing) / 3
        let col2X = 2 * (cellW + spacing)
        let row2Y = 2 * (cellH + spacing)
        rects.append(CGRect(x: col2X, y: row2Y, width: cellW, height: cellH))
        return rects
    }

    /// A balanced equal-size grid for any count. Landscape-preferred
    /// (`rows = floor(sqrt(n))`, so wider than tall) with a partial final row
    /// centered horizontally. For n=3 this is 3-across; for n=5 it is 3 on
    /// top and 2 centered below.
    static func evenGridRects(
        for count: Int,
        in c: CGSize,
        spacing: CGFloat = defaultSpacing
    ) -> [CGRect] {
        guard count > 0, c.width > 0, c.height > 0 else { return [] }
        let n = min(count, 9)
        let rows: Int, cols: Int
        if isPortrait(c) {
            // A tall container gets its shape from `bestFitGrid` instead, so
            // the tiles stack rather than squeezing 16:9 video into narrow
            // full-height columns.
            (cols, rows) = bestFitGrid(n: n, in: c, spacing: spacing)
        } else {
            rows = max(1, Int(Double(n).squareRoot()))
            cols = Int((Double(n) / Double(rows)).rounded(.up))
        }
        return gridRects(cols: cols, rows: rows, count: n, in: c, spacing: spacing)
    }

    /// `cols × rows` in reading order with a centered partial final row.
    /// Shared by `evenGridRects` and the portrait tables.
    private static func gridRects(
        cols: Int,
        rows: Int,
        count: Int,
        in c: CGSize,
        spacing: CGFloat
    ) -> [CGRect] {
        let w = (c.width  - CGFloat(cols - 1) * spacing) / CGFloat(cols)
        let h = (c.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)
        var rects: [CGRect] = []
        rects.reserveCapacity(count)
        var remaining = count
        for row in 0..<rows {
            let inRow = min(cols, remaining)
            guard inRow > 0 else { break }
            // Center a partial final row.
            let rowW = CGFloat(inRow) * w + CGFloat(inRow - 1) * spacing
            let xStart = (c.width - rowW) / 2
            for i in 0..<inRow {
                rects.append(CGRect(
                    x: xStart + CGFloat(i) * (w + spacing),
                    y: CGFloat(row) * (h + spacing),
                    width: w, height: h
                ))
            }
            remaining -= inRow
        }
        return rects
    }

    // MARK: - Portrait

    /// True when the container is taller than it is wide. A square container
    /// counts as landscape, which is also what guarantees `transposed` cannot
    /// recurse: it swaps the axes before re-entering, so the inner call always
    /// sees a landscape-or-square container.
    static func isPortrait(_ c: CGSize) -> Bool { c.height > c.width }

    /// Build a landscape table in an axis-swapped container, flip every rect
    /// back, and re-sort into reading order.
    ///
    /// Geometry transposes cleanly — a hero on the left becomes a hero on top.
    /// The ORDER does not: transposing walks a grid column-major, so tile 2 of
    /// a 5-up would land bottom-left instead of top-right. Sorting by (y, x)
    /// restores the reading order the landscape table had, which is what keeps
    /// each tile in the same relative slot across a rotation.
    private static func transposed(_ c: CGSize, _ build: (CGSize) -> [CGRect]) -> [CGRect] {
        build(CGSize(width: c.height, height: c.width))
            .map { CGRect(x: $0.minY, y: $0.minX, width: $0.height, height: $0.width) }
            .sorted { a, b in
                // 1pt of slop so tiles sharing a row survive rounding.
                abs(a.minY - b.minY) > 1 ? a.minY < b.minY : a.minX < b.minX
            }
    }

    /// Portrait counterpart of the per-N landscape table.
    ///
    /// The asymmetric hero shapes (3, 5) transpose: the big tile moves from the
    /// left edge to the top and its followers wrap underneath. Everything else
    /// is a uniform grid shaped by `bestFitGrid`, so 2 tiles split top/bottom
    /// on a phone rather than standing up as two skinny full-height columns.
    private static func portraitRects(for n: Int, in c: CGSize, spacing: CGFloat) -> [CGRect] {
        switch n {
        case 1: return layout1(c)
        case 3: return transposed(c) { layout3($0, spacing: spacing) }
        case 5: return transposed(c) { layout5($0, spacing: spacing) }
        default:
            let (cols, rows) = bestFitGrid(n: n, in: c, spacing: spacing)
            return gridRects(cols: cols, rows: rows, count: n, in: c, spacing: spacing)
        }
    }

    /// Pick the `cols × rows` split that renders the most video.
    ///
    /// Candidates are scored by the area a 16:9 frame actually paints inside
    /// one cell, letterboxing included — the metric that matters, because a
    /// cell far off the source aspect is mostly black bars. On a 393×780 phone
    /// that resolves 2 tiles to 1×2 and 4 tiles to 1×4; a squarer iPad
    /// container still resolves 4 to 2×2.
    private static func bestFitGrid(n: Int, in c: CGSize, spacing: CGFloat) -> (cols: Int, rows: Int) {
        let targetAspect: CGFloat = 16.0 / 9.0
        var best = (cols: 1, rows: max(1, n))
        var bestArea: CGFloat = -1
        for rows in 1...max(1, n) {
            let cols = Int((Double(n) / Double(rows)).rounded(.up))
            // Reject shapes whose final row would be entirely empty (4 tiles
            // in 3 rows of 2), which throw away a row's worth of height.
            guard cols * (rows - 1) < n else { continue }
            let w = (c.width  - CGFloat(cols - 1) * spacing) / CGFloat(cols)
            let h = (c.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)
            guard w > 0, h > 0 else { continue }
            let videoW = min(w, h * targetAspect)
            let area = videoW * (videoW / targetAspect)
            if area > bestArea {
                bestArea = area
                best = (cols, rows)
            }
        }
        return best
    }

    // MARK: - Per-N layouts

    private static func layout1(_ c: CGSize) -> [CGRect] {
        [CGRect(origin: .zero, size: c)]
    }

    /// Two tiles side-by-side, full height. Landscape priority — a
    /// 2×1 vertical split would waste width on a widescreen display.
    private static func layout2(_ c: CGSize, spacing: CGFloat) -> [CGRect] {
        let w = (c.width - spacing) / 2
        return [
            CGRect(x: 0,            y: 0, width: w, height: c.height),
            CGRect(x: w + spacing,  y: 0, width: w, height: c.height)
        ]
    }

    /// Big tile on the left (2/3 container width, full height); two
    /// smaller tiles stacked on the right (1/3 width, half height each).
    private static func layout3(_ c: CGSize, spacing: CGFloat) -> [CGRect] {
        let bigW = (c.width - spacing) * 2 / 3
        let smallW = c.width - bigW - spacing
        let smallH = (c.height - spacing) / 2
        return [
            CGRect(x: 0, y: 0, width: bigW, height: c.height),
            CGRect(x: bigW + spacing, y: 0,              width: smallW, height: smallH),
            CGRect(x: bigW + spacing, y: smallH + spacing, width: smallW, height: smallH)
        ]
    }

    /// Classic 2×2.
    private static func layout4(_ c: CGSize, spacing: CGFloat) -> [CGRect] {
        uniformGrid(cols: 2, rows: 2, in: c, spacing: spacing)
    }

    /// 3×3 grid's top-left 2×2 merged into one big tile, then 4 small
    /// tiles fill the right column (2) and the bottom row's left two
    /// cells. The 3×3 corner (col=2, row=2) stays empty — the
    /// asymmetry reads as "focused stream with 4 followers".
    ///
    /// Tile order: big → (2,0) → (2,1) → (0,2) → (1,2)
    private static func layout5(_ c: CGSize, spacing: CGFloat) -> [CGRect] {
        let cellW = (c.width  - 2 * spacing) / 3
        let cellH = (c.height - 2 * spacing) / 3
        let bigW = 2 * cellW + spacing
        let bigH = 2 * cellH + spacing
        let col2X = 2 * (cellW + spacing)
        let row2Y = 2 * (cellH + spacing)
        return [
            CGRect(x: 0,                    y: 0,                  width: bigW,  height: bigH),
            CGRect(x: col2X,                y: 0,                  width: cellW, height: cellH),
            CGRect(x: col2X,                y: cellH + spacing,    width: cellW, height: cellH),
            CGRect(x: 0,                    y: row2Y,              width: cellW, height: cellH),
            CGRect(x: cellW + spacing,      y: row2Y,              width: cellW, height: cellH)
        ]
    }

    /// 3 columns × 2 rows.
    private static func layout6(_ c: CGSize, spacing: CGFloat) -> [CGRect] {
        uniformGrid(cols: 3, rows: 2, in: c, spacing: spacing)
    }

    /// 3×3 with bottom-left and bottom-right empty — centers the 7th
    /// tile at (col=1, row=2). Tiles 1–6 follow reading order through
    /// the top two rows, tile 7 is the centered bottom.
    private static func layout7(_ c: CGSize, spacing: CGFloat) -> [CGRect] {
        let w = (c.width  - 2 * spacing) / 3
        let h = (c.height - 2 * spacing) / 3
        var rects: [CGRect] = []
        rects.reserveCapacity(7)
        for row in 0..<2 {
            for col in 0..<3 {
                rects.append(CGRect(
                    x: CGFloat(col) * (w + spacing),
                    y: CGFloat(row) * (h + spacing),
                    width: w, height: h
                ))
            }
        }
        rects.append(CGRect(
            x: w + spacing,
            y: 2 * (h + spacing),
            width: w, height: h
        ))
        return rects
    }

    /// 3×3 with the bottom-center cell (col=1, row=2) empty.
    /// Tile order: reading order skipping (1,2).
    private static func layout8(_ c: CGSize, spacing: CGFloat) -> [CGRect] {
        let w = (c.width  - 2 * spacing) / 3
        let h = (c.height - 2 * spacing) / 3
        let positions: [(col: Int, row: Int)] = [
            (0,0),(1,0),(2,0),
            (0,1),(1,1),(2,1),
            (0,2),        (2,2)   // skip (1,2)
        ]
        return positions.map { pos in
            CGRect(
                x: CGFloat(pos.col) * (w + spacing),
                y: CGFloat(pos.row) * (h + spacing),
                width: w, height: h
            )
        }
    }

    /// Full 3×3.
    private static func layout9(_ c: CGSize, spacing: CGFloat) -> [CGRect] {
        uniformGrid(cols: 3, rows: 3, in: c, spacing: spacing)
    }

    // MARK: - Shared helpers

    /// Uniform `cols × rows` grid, reading order (row-major, top-left
    /// first). Used by the symmetric layouts (2×2, 3×2, 3×3) to avoid
    /// repeating the same nested-loop shape.
    private static func uniformGrid(
        cols: Int,
        rows: Int,
        in c: CGSize,
        spacing: CGFloat
    ) -> [CGRect] {
        let w = (c.width  - CGFloat(cols - 1) * spacing) / CGFloat(cols)
        let h = (c.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)
        var rects: [CGRect] = []
        rects.reserveCapacity(cols * rows)
        for row in 0..<rows {
            for col in 0..<cols {
                rects.append(CGRect(
                    x: CGFloat(col) * (w + spacing),
                    y: CGFloat(row) * (h + spacing),
                    width: w, height: h
                ))
            }
        }
        return rects
    }
}
