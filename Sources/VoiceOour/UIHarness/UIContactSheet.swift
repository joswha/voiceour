// Offscreen UI harness. Compiled only when `UI_HARNESS` is defined.
//
// Every build defines it except `scripts/bundle.sh`, whose plain
// `swift build -c release` is therefore the only build that omits the harness --
// which is the entire point: these objects used to link into the shipping binary
// even though execution was gated at runtime on `--ui-harness`.
//
// `RenderOverrides` is deliberately NOT here: many production files read it, so
// it lives in `Sources/VoiceOour/RenderOverrides.swift` and is never gated.
#if UI_HARNESS

    import AppKit
    import Foundation

    // One image instead of twenty file reads.
    //
    // The contact sheet is the cheapest affordance in the harness: an agent opens a single
    // PNG and sees every scene at once, captioned with the scene id it needs for `--only`.
    // It is a review artifact, never a golden — it lives in `.build/ui-harness/` and its
    // bytes are allowed to move whenever the layout constants do.

    enum UIContactSheet {
        /// Tiles pre-rendered scene PNGs into one captioned sheet.
        ///
        /// Tiles are scaled down to fit a fixed box (never up past their own pixel size), so
        /// a sheet of twenty 1280x860 consoles stays around 1400 px wide instead of 6400.
        static func compose(_ tiles: [(id: String, png: Data)], columns: Int) throws -> Data {
            guard !tiles.isEmpty else { throw UIContactSheetError.noTiles }
            let cells = tiles.map(makeCell)
            let grid = Grid(cells: cells, columns: max(1, columns))
            let pixelsWide = Int(grid.sheetSize.width)
            let pixelsHigh = Int(grid.sheetSize.height)
            guard
                let sheet = UIPNG.makeBitmap(
                    pixelsWide: pixelsWide,
                    pixelsHigh: pixelsHigh,
                    pointSize: grid.sheetSize
                )
            else {
                throw UIContactSheetError.bitmapUnavailable(width: pixelsWide, height: pixelsHigh)
            }
            try render(cells: cells, grid: grid, into: sheet)
            return try UIPNG.encode(sheet)
        }
    }

    // MARK: - Layout

    extension UIContactSheet {
        private enum Layout {
            static let maximumTileWidth: CGFloat = 340
            static let maximumTileHeight: CGFloat = 260
            static let captionHeight: CGFloat = 18
            static let padding: CGFloat = 12
        }

        private struct Cell {
            let identifier: String
            let bitmap: NSBitmapImageRep?
            let size: CGSize
        }

        /// Columns are uniform so the grid reads as a grid; row height is per-row so a sheet
        /// mixing 1280x860 consoles with 420x120 overlays does not pad every short row up to
        /// the tallest scene in the catalog. Tiles sit on the bottom of their cell, directly
        /// above their caption.
        private struct Grid {
            let columns: Int
            let cellWidth: CGFloat
            let sheetSize: CGSize
            private let rowHeights: [CGFloat]
            private let rowTops: [CGFloat]

            init(cells: [Cell], columns: Int) {
                self.columns = columns
                cellWidth = cells.map(\.size.width).max() ?? Layout.maximumTileWidth

                var heights: [CGFloat] = []
                var start = 0
                while start < cells.count {
                    let end = min(start + columns, cells.count)
                    heights.append(cells[start..<end].map(\.size.height).max() ?? Layout.maximumTileHeight)
                    start = end
                }

                var tops: [CGFloat] = []
                tops.reserveCapacity(heights.count)
                var cursor = Layout.padding
                for height in heights {
                    tops.append(cursor)
                    cursor += height + Layout.captionHeight + Layout.padding
                }

                rowHeights = heights
                rowTops = tops
                sheetSize = CGSize(
                    width: (Layout.padding + CGFloat(columns) * (cellWidth + Layout.padding)).rounded(.up),
                    height: max(cursor, Layout.padding * 2).rounded(.up)
                )
            }

            /// Bottom-left origin of the tile-plus-caption box, laid out top to bottom.
            func origin(of index: Int) -> CGPoint {
                let row = index / columns
                return CGPoint(
                    x: Layout.padding + CGFloat(index % columns) * (cellWidth + Layout.padding),
                    y: sheetSize.height - rowTops[row] - (rowHeights[row] + Layout.captionHeight)
                )
            }
        }

        private static func makeCell(_ tile: (id: String, png: Data)) -> Cell {
            guard let bitmap = NSBitmapImageRep(data: tile.png), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else {
                let fallback = CGSize(width: Layout.maximumTileWidth, height: Layout.captionHeight * 2)
                return Cell(identifier: tile.id, bitmap: nil, size: fallback)
            }
            let pixelWidth = CGFloat(bitmap.pixelsWide)
            let pixelHeight = CGFloat(bitmap.pixelsHigh)
            let factor = min(
                Layout.maximumTileWidth / pixelWidth,
                Layout.maximumTileHeight / pixelHeight,
                1
            )
            return Cell(
                identifier: tile.id,
                bitmap: bitmap,
                size: CGSize(width: (pixelWidth * factor).rounded(.up), height: (pixelHeight * factor).rounded(.up))
            )
        }
    }

    // MARK: - Drawing

    extension UIContactSheet {
        private static var backgroundColor: NSColor { NSColor(calibratedWhite: 0.11, alpha: 1) }
        private static var borderColor: NSColor { NSColor(calibratedWhite: 1, alpha: 0.16) }
        private static var missingColor: NSColor { NSColor(calibratedRed: 0.42, green: 0.13, blue: 0.13, alpha: 1) }
        private static var captionColor: NSColor { NSColor(calibratedWhite: 0.82, alpha: 1) }

        private static func render(cells: [Cell], grid: Grid, into sheet: NSBitmapImageRep) throws {
            guard let context = NSGraphicsContext(bitmapImageRep: sheet) else {
                throw UIContactSheetError.contextUnavailable
            }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            context.shouldAntialias = true
            context.imageInterpolation = .high
            // Pinned rather than inherited: font smoothing is a real pixel lever here.
            context.cgContext.setShouldSmoothFonts(false)

            backgroundColor.setFill()
            NSRect(origin: .zero, size: grid.sheetSize).fill()
            for (index, cell) in cells.enumerated() {
                draw(cell, at: grid.origin(of: index), grid: grid)
            }
            context.flushGraphics()
        }

        private static func draw(_ cell: Cell, at origin: CGPoint, grid: Grid) {
            let tile = NSRect(
                x: origin.x + ((grid.cellWidth - cell.size.width) / 2).rounded(),
                y: origin.y + Layout.captionHeight,
                width: cell.size.width,
                height: cell.size.height
            )
            if let bitmap = cell.bitmap {
                _ = bitmap.draw(
                    in: tile,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: nil
                )
            } else {
                missingColor.setFill()
                tile.fill()
            }
            // A hairline keeps a blank or flat-tinted scene visible against the background.
            borderColor.setStroke()
            NSBezierPath(rect: tile.insetBy(dx: -0.5, dy: -0.5)).stroke()

            let caption = NSRect(x: origin.x, y: origin.y, width: grid.cellWidth, height: Layout.captionHeight)
            label(cell.identifier).draw(in: caption.insetBy(dx: 2, dy: 1))
        }

        private static func label(_ identifier: String) -> NSAttributedString {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingMiddle
            return NSAttributedString(
                string: identifier,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: captionColor,
                    .paragraphStyle: style,
                ]
            )
        }
    }

    // MARK: - Errors

    enum UIContactSheetError: Error, CustomStringConvertible {
        case noTiles
        case bitmapUnavailable(width: Int, height: Int)
        case contextUnavailable

        var description: String {
            switch self {
            case .noTiles:
                "contact sheet needs at least one rendered scene"
            case .bitmapUnavailable(let width, let height):
                "cannot allocate a \(width)x\(height) contact-sheet bitmap"
            case .contextUnavailable:
                "cannot bind a drawing context to the contact-sheet bitmap"
            }
        }
    }

#endif
