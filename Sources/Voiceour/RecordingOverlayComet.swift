import AppKit
import SwiftUI

/// A random-emoji comet: each session picks a random emoji as the head and trails it
/// in that emoji's OWN colour — sampled from the glyph's pixels — degrading bright →
/// dark → transparent. Deliberately playful. SwiftUI Canvas + AppKit colour sampling.
/// Sized to the control disc it stands in for while the finish action is unavailable.
struct FrostedCometIndicator: View {
    /// Rolled once per session by `RecordingOverlayModel`, not per mount: two
    /// `@ViewBuilder` branches each owning a `@State` head gave one dictation two
    /// different emoji.
    let head: CometEmoji

    private var a11y = A11y()

    init(head: CometEmoji) {
        self.head = head
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval, paused: false)) { timeline in
            Canvas { context, size in
                render(&context, size: size, date: timeline.date)
            }
        }
        .frame(
            width: RecordingOverlayMetrics.Disc.hitSize,
            height: RecordingOverlayMetrics.Disc.hitSize
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var frameInterval: Double {
        a11y.reduceMotion
            ? RecordingOverlayMetrics.Comet.reducedFrameInterval
            : RecordingOverlayMetrics.Comet.frameInterval
    }

    // MARK: - Master draw
    private func render(_ ctx: inout GraphicsContext, size: CGSize, date: Date) {
        let elapsed = date.timeIntervalSinceReferenceDate

        // Reduce Motion stops the head TRAVELLING — the intensity reduction the
        // setting asks for — but the mark keeps breathing. Pausing the timeline froze
        // the only "work is happening" signal on the surface, so a four-second
        // transcription was indistinguishable from a hung sidecar.
        let phase =
            a11y.reduceMotion
            ? RecordingOverlayMetrics.Comet.restingPhase
            : CGFloat(
                elapsed.truncatingRemainder(
                    dividingBy: RecordingOverlayMetrics.Comet.orbitPeriod
                ) / RecordingOverlayMetrics.Comet.orbitPeriod
            )

        if a11y.reduceMotion {
            let floor = RecordingOverlayMetrics.Comet.breatheFloor
            let cycle = cos(2 * .pi * elapsed / RecordingOverlayMetrics.Comet.breathePeriod)
            ctx.opacity = floor + (1 - floor) * (0.5 + 0.5 * cycle)
        }

        let rect = CGRect(origin: .zero, size: size)
            .insetBy(
                dx: RecordingOverlayMetrics.Comet.orbitInset,
                dy: RecordingOverlayMetrics.Comet.orbitInset
            )
        // `>=` rather than `>`: at the disc's measure the orbit is a circle, where
        // the straight runs are zero-length and the perimeter is 2πr.
        guard rect.width >= rect.height, rect.height > 0 else { return }
        let orbit = Orbit(rect: rect)

        // Soft bloom underlay → an ambient halo around the streak, in the emoji hue.
        ctx.drawLayer { under in
            under.addFilter(.blur(radius: RecordingOverlayMetrics.Comet.bloomBlur))
            drawTrailRibbon(
                &under,
                orbit: orbit,
                headPhase: phase,
                widthScale: RecordingOverlayMetrics.Comet.bloomWidthScale,
                alphaScale: RecordingOverlayMetrics.Comet.bloomAlphaScale
            )
        }

        // Crisp primary ribbon.
        drawTrailRibbon(
            &ctx, orbit: orbit, headPhase: phase,
            widthScale: 1.0, alphaScale: 1.0)

        // The emoji head sits on top of the trail terminus.
        drawHead(&ctx, orbit: orbit, headPhase: phase)
    }

    // MARK: - Trail (tapered ribbon polygon, tinted to the emoji's colour)
    private func drawTrailRibbon(
        _ ctx: inout GraphicsContext,
        orbit: Orbit,
        headPhase: CGFloat,
        widthScale: CGFloat,
        alphaScale: CGFloat
    ) {
        let perimeter = orbit.perimeter
        let headArcLen = headPhase * perimeter
        let trailArcLen = RecordingOverlayMetrics.Comet.trailFractionOfPerimeter * perimeter
        let n = RecordingOverlayMetrics.Comet.trailSampleCount

        for i in 0..<n {
            let uA = CGFloat(i) / CGFloat(n)
            let uB = CGFloat(i + 1) / CGFloat(n)

            let sA = headArcLen - trailArcLen * (1 - uA)
            let sB = headArcLen - trailArcLen * (1 - uB)
            let a = orbit.sample(atArcLength: sA)
            let b = orbit.sample(atArcLength: sB)

            let wA = RecordingOverlayMetrics.Comet.ribbonHeadWidth * widthScale * widthProfile(uA)
            let wB = RecordingOverlayMetrics.Comet.ribbonHeadWidth * widthScale * widthProfile(uB)

            let perpA = CGVector(dx: -a.tangent.dy, dy: a.tangent.dx)
            let perpB = CGVector(dx: -b.tangent.dy, dy: b.tangent.dx)

            let leftA = CGPoint(
                x: a.position.x + perpA.dx * wA * 0.5,
                y: a.position.y + perpA.dy * wA * 0.5)
            let rightA = CGPoint(
                x: a.position.x - perpA.dx * wA * 0.5,
                y: a.position.y - perpA.dy * wA * 0.5)
            let leftB = CGPoint(
                x: b.position.x + perpB.dx * wB * 0.5,
                y: b.position.y + perpB.dy * wB * 0.5)
            let rightB = CGPoint(
                x: b.position.x - perpB.dx * wB * 0.5,
                y: b.position.y - perpB.dy * wB * 0.5)

            var quad = Path()
            quad.move(to: leftA)
            quad.addLine(to: leftB)
            quad.addLine(to: rightB)
            quad.addLine(to: rightA)
            quad.closeSubpath()

            let color = trailColor(atU: (uA + uB) * 0.5, alphaScale: alphaScale)
            ctx.fill(quad, with: .color(color))
        }
    }

    // MARK: - Head (the emoji glyph + a soft same-hue glow)
    private func drawHead(
        _ ctx: inout GraphicsContext,
        orbit: Orbit,
        headPhase: CGFloat
    ) {
        let sample = orbit.sample(atArcLength: headPhase * orbit.perimeter)
        let c = sample.position

        // Glow in the emoji's own colour so the head reads as the source of the trail.
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: RecordingOverlayMetrics.Comet.headGlowBlur))
            let r = RecordingOverlayMetrics.Comet.headGlowRadius
            layer.fill(
                Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(
                            color: Color(hue: head.hue, saturation: head.saturation, brightness: 1.0, opacity: 0.5),
                            location: 0.0),
                        .init(
                            color: Color(hue: head.hue, saturation: head.saturation, brightness: 0.85, opacity: 0.0),
                            location: 1.0),
                    ]),
                    center: c, startRadius: 0, endRadius: r
                )
            )
        }

        // The emoji itself, drawn straight into the Canvas at its true colours.
        ctx.draw(
            Text(head.glyph)
                .font(.system(size: RecordingOverlayMetrics.Comet.headFontSize)),
            at: c,
            anchor: .center
        )
    }

    // MARK: - Curves
    private func widthProfile(_ u: CGFloat) -> CGFloat {
        let t = max(0, min(1, u))
        return CGFloat(pow(Double(t), RecordingOverlayMetrics.Comet.ribbonWidthExponent))
    }

    /// Single-hue trail: the emoji's colour, bright at the head, degrading to a
    /// dark, transparent tail.
    private func trailColor(atU u: CGFloat, alphaScale: CGFloat) -> Color {
        let t = max(0, min(1, Double(u)))
        let brightness = 0.22 + 0.78 * pow(t, 0.8)  // dark tail → bright head
        let saturation = head.saturation * (t > 0.9 ? 0.75 : 1.0)  // a touch whiter right at the head
        let alpha = pow(t, 1.5) * Double(alphaScale)
        return Color(
            hue: head.hue,
            saturation: min(1, max(0, saturation)),
            brightness: min(1, brightness),
            opacity: alpha)
    }

    // MARK: - Arc-length-parametrized capsule orbit
    private struct Orbit {
        let rect: CGRect
        let radius: CGFloat
        let straight: CGFloat
        let arc: CGFloat
        let perimeter: CGFloat
        let leftCenter: CGPoint
        let rightCenter: CGPoint

        struct Sample {
            let position: CGPoint
            let tangent: CGVector  // unit
        }

        init(rect: CGRect) {
            self.rect = rect
            let r = rect.height / 2
            self.radius = r
            self.straight = max(0, rect.width - 2 * r)
            self.arc = .pi * r
            self.perimeter = 2 * straight + 2 * arc
            self.leftCenter = CGPoint(x: rect.minX + r, y: rect.midY)
            self.rightCenter = CGPoint(x: rect.maxX - r, y: rect.midY)
        }

        func sample(atArcLength arg: CGFloat) -> Sample {
            var s = arg.truncatingRemainder(dividingBy: perimeter)
            if s < 0 { s += perimeter }

            // Top straight: left → right along y = minY.
            if s < straight {
                return Sample(
                    position: CGPoint(x: rect.minX + radius + s, y: rect.minY),
                    tangent: CGVector(dx: 1, dy: 0)
                )
            }
            s -= straight

            // Right arc: top → bottom, through right-most (theta -π/2 → +π/2).
            if s < arc {
                let theta = -CGFloat.pi / 2 + s / radius
                return Sample(
                    position: CGPoint(
                        x: rightCenter.x + radius * cos(theta),
                        y: rightCenter.y + radius * sin(theta)),
                    tangent: CGVector(dx: -sin(theta), dy: cos(theta))
                )
            }
            s -= arc

            // Bottom straight: right → left along y = maxY.
            if s < straight {
                return Sample(
                    position: CGPoint(x: rect.maxX - radius - s, y: rect.maxY),
                    tangent: CGVector(dx: -1, dy: 0)
                )
            }
            s -= straight

            // Left arc: bottom → top, through left-most (theta π/2 → 3π/2).
            let theta = CGFloat.pi / 2 + s / radius
            return Sample(
                position: CGPoint(
                    x: leftCenter.x + radius * cos(theta),
                    y: leftCenter.y + radius * sin(theta)),
                tangent: CGVector(dx: -sin(theta), dy: cos(theta))
            )
        }
    }
}

/// A random emoji + a colour sampled from that emoji's own glyph pixels, so the
/// comet can trail in "its" colour. Multicolour glyphs collapse to a
/// saturation-weighted dominant hue — best-effort, by design.
// Internal rather than private so the harness can pin a fixed head.
struct CometEmoji {
    let glyph: String
    let hue: Double
    let saturation: Double

    static let pool: [String] = [
        "👽", "🔥", "💧", "⭐️", "🍎", "🍇", "🌸", "🌊", "🍋", "🌿",
        "🔮", "🌈", "🍊", "🫐", "🌶️", "🦠", "💜", "💚", "❤️", "💛",
        "💙", "🧡", "🩷", "🌙", "☄️", "🐸", "🍀", "🌻", "🪐", "👾",
        "🤖", "🎃", "🍭", "🧊", "🌺", "🍄", "⚡️", "✨", "💫", "🥝",
    ]

    static func random() -> CometEmoji {
        let glyph = pool.randomElement() ?? "☄️"
        let (h, s) = dominantHueSaturation(of: glyph)
        return CometEmoji(glyph: glyph, hue: h, saturation: s)
    }

    /// Renders the emoji to a small bitmap and returns a saturation-weighted
    /// average hue/saturation of its opaque pixels. Warm-orange fallback on failure.
    private static func dominantHueSaturation(of emoji: String) -> (Double, Double) {
        let px = 28
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 24)]
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )
        else {
            return (0.08, 0.85)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (emoji as NSString).draw(
            in: NSRect(x: 0, y: 0, width: px, height: px),
            withAttributes: attributes
        )
        NSGraphicsContext.restoreGraphicsState()

        var sumR = 0.0
        var sumG = 0.0
        var sumB = 0.0
        var weight = 0.0
        for y in 0..<px {
            for x in 0..<px {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let alpha = Double(color.alphaComponent)
                if alpha < 0.25 { continue }
                let r = Double(color.redComponent)
                let g = Double(color.greenComponent)
                let b = Double(color.blueComponent)
                let maxc = max(r, g, b)
                let minc = min(r, g, b)
                let sat = maxc <= 0 ? 0 : (maxc - minc) / maxc
                let w = alpha * (0.12 + sat)  // vivid pixels dominate; greys still count a little
                sumR += r * w
                sumG += g * w
                sumB += b * w
                weight += w
            }
        }
        guard weight > 0 else { return (0.08, 0.85) }

        let avg = NSColor(
            deviceRed: CGFloat(sumR / weight),
            green: CGFloat(sumG / weight),
            blue: CGFloat(sumB / weight),
            alpha: 1
        )
        var h: CGFloat = 0
        var s: CGFloat = 0
        var brightness: CGFloat = 0
        var a: CGFloat = 0
        avg.getHue(&h, saturation: &s, brightness: &brightness, alpha: &a)
        // Nudge saturation so trails read colourful even for muted glyphs.
        return (Double(h), Double(min(1, s * 1.2 + 0.12)))
    }
}
