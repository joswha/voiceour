import AppKit
import SwiftUI

/// The studio the Settings showroom stands the body in: its light and its floor.
///
/// Both exist so the preview reads as an object in a room rather than a sticker on a pane,
/// and both stay outside the body's own image. The light is the look's own generated light —
/// its white balance and its underglow — and nothing is sampled from the screen. The floor is
/// drawn from the image the production engine just presented, so the body itself keeps every
/// pixel the renderer gives it.
enum ShowroomStage {
    /// The stage's light for one look: a spotlight tinted by the look's white balance and the
    /// underglow's colour and strength. Two colour conversions per look change; nothing per
    /// frame.
    struct Lighting: Equatable {
        /// The top spotlight's colour: the look's room multipliers scaled so their brightest
        /// channel is 1, a soft light that never passes white. White for the stock room.
        var spot: Color
        /// The underglow's colour at full value, or nil while the underglow is off.
        var underglow: Color?
        /// `0...1`, and 0 while the underglow is off.
        var underglowStrength: Double

        init(look: MercuryLook) {
            spot = look.lighting.whiteBalance.map(Self.light) ?? .white
            underglow = look.lighting.underglow.map { Self.light($0.color) }
            underglowStrength = look.underglowStrength
        }

        /// A linear-RGB light at full value: the colour of the light, not its power, which the
        /// stage sets itself.
        private static func light(_ linear: SIMD3<Double>) -> Color {
            let peak = Swift.max(linear.x, linear.y, linear.z)
            guard peak > 0, peak.isFinite else { return .white }
            let value = linear / peak
            return Color(.sRGBLinear, red: value.x, green: value.y, blue: value.z)
        }
    }

    /// The vertical scale of the reflection against the body: a floor seen from above
    /// foreshortens what it mirrors.
    private static let reflectionSquash = 0.55
    /// The reflection's opacity where it meets the body; it fades linearly to 0 at its end.
    private static let reflectionOpacity = 0.28
    /// The contact shadow's opacity at its centre.
    private static let shadowOpacity = 0.5
    /// The contact shadow's half-width against half the body's width: it sits under the body
    /// rather than past its ends.
    private static let shadowWidthFraction = 0.92
    /// The contact shadow's half-height against the body's height.
    private static let shadowHeightFraction = 0.16
    /// A pixel at or above half coverage is the body's; the antialiased rim below it is not.
    private static let opaqueAlpha: UInt8 = 128

    /// The floor under `body`: a soft contact shadow sized from the body's opaque bounds, and
    /// the body mirrored about its base, squashed to 55 % of its height and fading from 0.28
    /// opacity to 0.
    ///
    /// The image is `body`'s pixel width and twice its pixel height, in the body canvas's own
    /// coordinates: its top half is the canvas, so the floor view shares the surface's origin
    /// and width, is twice its height, and sits behind it. The shadow centres on the base row
    /// and the reflection runs down from it into the lower half. A body with no opaque pixel
    /// has no floor: nil.
    ///
    /// A deterministic CPU raster, RGBA8 premultiplied in device RGB like the body, with no
    /// filter, blur or mask: one pass over the body's alpha for its bounds, then plain
    /// arithmetic over the shadow's and the reflection's rows only, with one 784×272 px buffer
    /// per presented frame for the showroom's 784×136 px body. Its measured cost is recorded in
    /// mercury-renderer.md's showroom section.
    static func floorImage(from body: CGImage) -> CGImage? {
        let width = body.width
        let height = body.height
        guard width > 0, height > 0, let source = SourcePixels(body) else { return nil }
        return source.withBytes { pixels, bytesPerRow in
            guard let bounds = opaqueBounds(pixels, bytesPerRow: bytesPerRow, width: width, height: height) else {
                return nil
            }
            let floorHeight = height * 2
            guard
                let context = CGContext(
                    data: nil,
                    width: width,
                    height: floorHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ),
                let data = context.data
            else { return nil }
            let floor = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * floorHeight)
            let floorBytesPerRow = context.bytesPerRow
            floor.initialize(repeating: 0, count: floorBytesPerRow * floorHeight)
            drawShadow(into: floor, bytesPerRow: floorBytesPerRow, width: width, height: floorHeight, under: bounds)
            drawReflection(
                of: pixels,
                bytesPerRow: bytesPerRow,
                bodyHeight: height,
                into: floor,
                floorBytesPerRow: floorBytesPerRow,
                width: width,
                floorHeight: floorHeight,
                bounds: bounds
            )
            return context.makeImage()
        }
    }

    /// The body's opaque pixels' bounds: columns `minX...maxX`, rows `minY...maxY`, rows
    /// counted from the top.
    private struct Bounds {
        var minX: Int
        var maxX: Int
        var minY: Int
        var maxY: Int
    }

    private static func opaqueBounds(
        _ pixels: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        width: Int,
        height: Int
    ) -> Bounds? {
        var bounds = Bounds(minX: width, maxX: -1, minY: height, maxY: -1)
        for y in 0..<height {
            let row = pixels + y * bytesPerRow
            var first = -1
            var last = -1
            for x in 0..<width where row[x * 4 + 3] >= opaqueAlpha {
                if first < 0 { first = x }
                last = x
            }
            guard first >= 0 else { continue }
            bounds.minX = Swift.min(bounds.minX, first)
            bounds.maxX = Swift.max(bounds.maxX, last)
            if bounds.minY > y { bounds.minY = y }
            bounds.maxY = y
        }
        return bounds.maxY >= 0 ? bounds : nil
    }

    /// A black ellipse centred on the body's base edge, `(1 − e)²` in its normalized squared
    /// radius `e`, so it has no hard rim.
    private static func drawShadow(
        into floor: UnsafeMutablePointer<UInt8>,
        bytesPerRow: Int,
        width: Int,
        height: Int,
        under bounds: Bounds
    ) {
        let bodyWidth = Double(bounds.maxX + 1 - bounds.minX)
        let bodyHeight = Double(bounds.maxY + 1 - bounds.minY)
        let centerX = Double(bounds.minX) + bodyWidth / 2
        let centerY = Double(bounds.maxY + 1)
        let radiusX = Swift.max(1, bodyWidth / 2 * shadowWidthFraction)
        let radiusY = Swift.max(2, bodyHeight * shadowHeightFraction)
        let firstRow = Swift.max(0, Int((centerY - radiusY).rounded(.down)))
        let lastRow = Swift.min(height - 1, Int((centerY + radiusY).rounded(.up)))
        let firstColumn = Swift.max(0, Int((centerX - radiusX).rounded(.down)))
        let lastColumn = Swift.min(width - 1, Int((centerX + radiusX).rounded(.up)))
        guard firstRow <= lastRow, firstColumn <= lastColumn else { return }
        for y in firstRow...lastRow {
            let dy = (Double(y) + 0.5 - centerY) / radiusY
            let dy2 = dy * dy
            guard dy2 < 1 else { continue }
            let row = floor + y * bytesPerRow
            for x in firstColumn...lastColumn {
                let dx = (Double(x) + 0.5 - centerX) / radiusX
                let e = dx * dx + dy2
                guard e < 1 else { continue }
                let falloff = (1 - e) * (1 - e)
                // Black premultiplied: the colour bytes stay 0.
                row[x * 4 + 3] = UInt8(Swift.min(255, Int(shadowOpacity * falloff * 255 + 0.5)))
            }
        }
    }

    /// The body flipped about its base edge and squashed, each floor row a linear blend of the
    /// two body rows it maps between, scaled by the row's fade and laid over the shadow.
    private static func drawReflection(
        of pixels: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        bodyHeight: Int,
        into floor: UnsafeMutablePointer<UInt8>,
        floorBytesPerRow: Int,
        width: Int,
        floorHeight: Int,
        bounds: Bounds
    ) {
        let base = bounds.maxY + 1
        let rows = Int((Double(base - bounds.minY) * reflectionSquash).rounded(.up))
        guard rows > 0 else { return }
        // The antialiased rim around the opaque bounds reflects too.
        let firstColumn = Swift.max(0, bounds.minX - 2)
        let lastColumn = Swift.min(width - 1, bounds.maxX + 2)
        for offset in 0..<rows {
            let y = base + offset
            guard y < floorHeight else { break }
            let distance = Double(offset) + 0.5
            let fade = reflectionOpacity * (1 - distance / Double(rows))
            guard fade > 0 else { continue }
            // The body row whose centre the mirrored, squashed floor row samples.
            let sampled = Double(base) - distance / reflectionSquash - 0.5
            let upper = Int(sampled.rounded(.down))
            let blend = sampled - Double(upper)
            let upperWeight = Float(fade * (1 - blend))
            let lowerWeight = Float(fade * blend)
            let upperRow: UnsafePointer<UInt8>? = upper >= 0 && upper < bodyHeight ? pixels + upper * bytesPerRow : nil
            let lower = upper + 1
            let lowerRow: UnsafePointer<UInt8>? = lower >= 0 && lower < bodyHeight ? pixels + lower * bytesPerRow : nil
            guard upperRow != nil || lowerRow != nil else { continue }
            let row = floor + y * floorBytesPerRow
            for x in firstColumn...lastColumn {
                let index = x * 4
                var source = SIMD4<Float>(repeating: 0)
                if let upperRow {
                    source += Self.pixel(upperRow + index) * upperWeight
                }
                if let lowerRow {
                    source += Self.pixel(lowerRow + index) * lowerWeight
                }
                guard source.w > 0 else { continue }
                let destination = Self.pixel(UnsafePointer(row + index))
                let over = source + destination * (1 - source.w / 255)
                row[index] = Self.byte(over.x)
                row[index + 1] = Self.byte(over.y)
                row[index + 2] = Self.byte(over.z)
                row[index + 3] = Self.byte(over.w)
            }
        }
    }

    @inline(__always)
    private static func pixel(_ bytes: UnsafePointer<UInt8>) -> SIMD4<Float> {
        SIMD4(Float(bytes[0]), Float(bytes[1]), Float(bytes[2]), Float(bytes[3]))
    }

    @inline(__always)
    private static func byte(_ value: Float) -> UInt8 {
        UInt8(Swift.min(255, Swift.max(0, value + 0.5)))
    }

    /// The body's bytes as RGBA8 premultiplied: the engine's own image read in place, or any
    /// other image drawn once into that format.
    private struct SourcePixels {
        private let data: CFData
        private let bytesPerRow: Int

        init?(_ image: CGImage) {
            if Self.isEngineFormat(image), let data = image.dataProvider?.data {
                self.data = data
                bytesPerRow = image.bytesPerRow
                return
            }
            let bytesPerRow = image.width * 4
            guard
                let context = CGContext(
                    data: nil,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return nil }
            context.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let drawn = context.makeImage(), let data = drawn.dataProvider?.data else { return nil }
            self.data = data
            self.bytesPerRow = context.bytesPerRow
        }

        func withBytes<Result>(_ body: (UnsafePointer<UInt8>, Int) -> Result?) -> Result? {
            guard let bytes = CFDataGetBytePtr(data) else { return nil }
            return withExtendedLifetime(data) { body(bytes, bytesPerRow) }
        }

        private static func isEngineFormat(_ image: CGImage) -> Bool {
            image.bitsPerComponent == 8 && image.bitsPerPixel == 32
                && image.alphaInfo == .premultipliedLast
                && image.bitmapInfo.intersection(.byteOrderMask).rawValue == 0
                && image.colorSpace?.model == .rgb
                && image.bytesPerRow >= image.width * 4
        }
    }
}

/// Carries each presented body image to the showroom's floor view.
///
/// It exists so the floor follows the body at display cadence without a SwiftUI update: the
/// surface's `onPresent` hands it the image, and it sets the floor layer's contents directly.
/// It publishes nothing. Its cost per new image is one ``ShowroomStage/floorImage(from:)``.
@MainActor
final class ShowroomFloorLink {
    private weak var view: ShowroomFloorView?
    private var body: CGImage?
    private var floor: CGImage?

    init() {}

    /// Draws the floor under `body`; an image already shown draws nothing.
    func present(_ body: CGImage) {
        guard body !== self.body else { return }
        self.body = body
        floor = ShowroomStage.floorImage(from: body)
        MercuryLayerPresenter.present(floor, on: view?.layer)
    }

    /// A view attached after the body's first image shows the floor drawn for it at once.
    fileprivate func attach(_ view: ShowroomFloorView) {
        guard view !== self.view else { return }
        self.view = view
        MercuryLayerPresenter.present(floor, on: view.layer)
    }
}

/// The layer-backed view that shows the latest floor image, stretched over its bounds.
/// Decoration only: hidden from accessibility and from hit-testing.
@MainActor
final class ShowroomFloorView: NSView {
    override var isOpaque: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .linear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func isAccessibilityElement() -> Bool {
        false
    }
}

/// The showroom's floor: reflection and contact shadow under the body, from a
/// ``ShowroomFloorLink`` the surface's `onPresent` feeds. Frame it at the surface's width and
/// twice its height, top-aligned with the surface and behind it; see
/// ``ShowroomStage/floorImage(from:)``.
struct ShowroomFloor: NSViewRepresentable {
    private let link: ShowroomFloorLink

    init(link: ShowroomFloorLink) {
        self.link = link
    }

    func makeNSView(context: Context) -> ShowroomFloorView {
        let view = ShowroomFloorView()
        link.attach(view)
        return view
    }

    func updateNSView(_ view: ShowroomFloorView, context: Context) {
        link.attach(view)
    }
}
