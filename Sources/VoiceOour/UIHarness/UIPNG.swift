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
    import CryptoKit
    import Foundation

    /// Failures raised while turning an offscreen bitmap into byte-stable PNG data.
    enum UIPNGError: Error, LocalizedError {
        case encodingFailed(pixelsWide: Int, pixelsHigh: Int)

        var errorDescription: String? {
            switch self {
            case .encodingFailed(let pixelsWide, let pixelsHigh):
                return "PNG encoding failed for a \(pixelsWide)x\(pixelsHigh) bitmap."
            }
        }
    }

    /// Bitmap allocation, PNG encoding and content hashing for the offscreen harness.
    ///
    /// Everything here is deliberately free of AppKit *state*: no window, no run loop, no
    /// main-actor requirement. The contact sheet composes its own bitmaps through the same
    /// entry points the scene renderer uses, so the two artifact families are encoded by
    /// exactly one code path.
    enum UIPNG {
        /// Allocates an RGBA8 bitmap that the harness owns end to end.
        ///
        /// SHOWSTOPPER: this exists instead of `bitmapImageRepForCachingDisplay(in:)`, which
        /// embeds a 3149-byte iCCP display ICC profile plus a cICP chunk — i.e. it bakes the
        /// developer's monitor into every golden file. A hand-built `.deviceRGB` rep carries
        /// no profile at all, so the bytes are the same on any machine.
        ///
        /// `pointSize` is the *logical* size. Setting `rep.size` is what makes the scale
        /// factor real: a 2560x1720 pixel buffer whose size is 1280x860 points is a 2x
        /// raster, and `cacheDisplay` scales into it accordingly.
        ///
        /// The alpha channel is not decorative — a destination with alpha also declines
        /// subpixel font smoothing, which is the single largest source of raster drift
        /// measured on this app (see `UIHarnessRuntime.pinRasterisationFlags`).
        static func makeBitmap(pixelsWide: Int, pixelsHigh: Int, pointSize: CGSize) -> NSBitmapImageRep? {
            guard pixelsWide > 0, pixelsHigh > 0 else { return nil }
            guard
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: pixelsWide,
                    pixelsHigh: pixelsHigh,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                )
            else {
                return nil
            }
            rep.size = pointSize
            return rep
        }

        /// Encodes `rep` as PNG with no encoder options, so nothing machine-local (gamma
        /// hints, interlacing, compression tuning) can leak into the golden.
        static func encode(_ rep: NSBitmapImageRep) throws -> Data {
            guard let data = rep.representation(using: .png, properties: [:]) else {
                throw UIPNGError.encodingFailed(pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh)
            }
            return data
        }

        /// Lowercase hex SHA-256. Used both for capture identity and for comparing a fresh
        /// render against golden bytes read straight off disk.
        static func sha256(_ data: Data) -> String {
            let digest = SHA256.hash(data: data)
            var hex = String()
            hex.reserveCapacity(SHA256Digest.byteCount * 2)
            for byte in digest {
                hex.append(hexDigits[Int(byte >> 4)])
                hex.append(hexDigits[Int(byte & 0x0F)])
            }
            return hex
        }

        private static let hexDigits: [Character] = Array("0123456789abcdef")
    }

#endif
