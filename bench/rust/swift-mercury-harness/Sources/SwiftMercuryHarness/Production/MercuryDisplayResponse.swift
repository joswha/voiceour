import Foundation

/// A session's linear-light chrome response.
///
/// Two scene anchors solve its two parameters; the compiled ceiling is unreachable for
/// every finite input. The map is applied to luminance and the input RGB ratio is restored
/// afterwards, so conductor Fresnel remains the only material colour and exposure cannot
/// turn a bright room into an all-white body.
struct MercuryDisplayResponse: Equatable, Sendable {
    let exponent: Double
    let halfSaturation: Double
    let ceiling: Double
    let sceneMedian: Double
    let sceneHighlight: Double
    /// Solves
    ///
    /// `y(s) = ceiling / (1 + (halfSaturation / s)^exponent)`
    ///
    /// at two independent anchors. An input distribution without positive spread is not
    /// silently clamped into a different material; it is rejected for the caller to report.
    static func solve(
        sceneMedian: Double,
        sceneHighlight: Double,
        medianTarget: Double,
        highlightTarget: Double,
        ceiling: Double
    ) -> MercuryDisplayResponse? {
        guard
            sceneMedian.isFinite,
            sceneHighlight.isFinite,
            medianTarget.isFinite,
            highlightTarget.isFinite,
            ceiling.isFinite,
            sceneMedian > 0,
            sceneHighlight > sceneMedian,
            medianTarget > 0,
            highlightTarget > medianTarget,
            ceiling > highlightTarget
        else { return nil }

        let medianRatio = ceiling / medianTarget - 1
        let highlightRatio = ceiling / highlightTarget - 1
        let exponent = log(medianRatio / highlightRatio) / log(sceneHighlight / sceneMedian)
        guard exponent.isFinite, exponent > 0 else { return nil }
        let halfSaturation = sceneMedian * pow(medianRatio, 1 / exponent)
        guard halfSaturation.isFinite, halfSaturation > 0 else { return nil }
        return MercuryDisplayResponse(
            exponent: exponent,
            halfSaturation: halfSaturation,
            ceiling: ceiling,
            sceneMedian: sceneMedian,
            sceneHighlight: sceneHighlight
        )
    }

    /// Numerically stable at zero, subnormal values and both ends of `Double`'s finite range.
    /// Reuses the measured scene anchors while changing only the bounded display targets.
    func remapped(
        medianTarget: Double,
        highlightTarget: Double
    ) -> MercuryDisplayResponse? {
        Self.solve(
            sceneMedian: sceneMedian,
            sceneHighlight: sceneHighlight,
            medianTarget: medianTarget,
            highlightTarget: highlightTarget,
            ceiling: ceiling
        )
    }

    @inline(__always)
    func map(_ sceneLuminance: Double) -> Double {
        guard sceneLuminance > 0 else { return 0 }
        guard sceneLuminance.isFinite else { return ceiling }
        let logit = exponent * (log(halfSaturation) - log(sceneLuminance))
        let mapped: Double
        if logit >= 0 {
            let tail = exp(-logit)
            mapped = ceiling * tail / (1 + tail)
        } else {
            let tail = exp(logit)
            mapped = ceiling / (1 + tail)
        }
        // The analytic response approaches but never reaches the ceiling. Preserve that
        // property when `tail` underflows or addition rounds away its last bits.
        return Swift.min(mapped, ceiling.nextDown)
    }

    /// Restores the scene's channel ratio at the mapped luminance. If that ratio would
    /// leave the display gamut, desaturates toward neutral along a luminance-free vector;
    /// this keeps Rec.709 luminance exact while bounding every channel by `ceiling`.
    @inline(__always)
    func map(_ scene: SIMD3<Double>) -> SIMD3<Double> {
        let sceneLuminance = Self.luminance(scene)
        guard sceneLuminance > 0, sceneLuminance.isFinite else { return .zero }
        let mappedLuminance = map(sceneLuminance)
        let raw = scene * (mappedLuminance / sceneLuminance)
        let neutral = SIMD3<Double>(repeating: mappedLuminance)
        let difference = raw - neutral
        var amount = 1.0
        for channel in 0..<3 {
            let delta = difference[channel]
            if delta > 0 {
                amount = Swift.min(amount, (ceiling - mappedLuminance) / delta)
            } else if delta < 0 {
                amount = Swift.min(amount, mappedLuminance / -delta)
            }
        }
        return neutral + Swift.max(amount, 0) * difference
    }

    @inline(__always)
    static func luminance(_ value: SIMD3<Double>) -> Double {
        0.2126 * value.x + 0.7152 * value.y + 0.0722 * value.z
    }
}
