// Offscreen UI harness. Compiled only when `UI_HARNESS` is defined.
//
// The flag comes from `scripts/ui_harness.sh` (and so every `make ui-*` target) and
// from the `make test` / CI `swift test` steps. Ordinary builds omit it, the
// `swift build -c release` inside `scripts/bundle.sh` that ships included -- which is
// the entire point: these objects used to link into the shipping binary even though
// execution was gated at runtime on `--ui-harness`.
//
// `RenderOverrides` is deliberately NOT here: many production files read it, so
// it lives in `Sources/Voiceour/RenderOverrides.swift` and is never gated.
#if UI_HARNESS

    import AppKit
    import Foundation
    import SwiftUI

    /// Failures raised by the offscreen renderer itself.
    enum UIHarnessRuntimeError: Error, LocalizedError {
        case emptyViewBounds(pixelsWide: Int, pixelsHigh: Int)
        case bitmapAllocationFailed(pixelsWide: Int, pixelsHigh: Int)
        case captureProducedNoPixels(pixelsWide: Int, pixelsHigh: Int)
        case unsupportedBitmapLayout(bitsPerPixel: Int, samplesPerPixel: Int, isPlanar: Bool)

        var errorDescription: String? {
            switch self {
            case .emptyViewBounds(let pixelsWide, let pixelsHigh):
                return
                    "The hosted view rasterises to \(pixelsWide)x\(pixelsHigh) pixels; the scene size or the SwiftUI layout collapsed to nothing."
            case .bitmapAllocationFailed(let pixelsWide, let pixelsHigh):
                return "NSBitmapImageRep refused a \(pixelsWide)x\(pixelsHigh) RGBA8 buffer."
            case .captureProducedNoPixels(let pixelsWide, let pixelsHigh):
                return
                    "cacheDisplay(in:to:) left the \(pixelsWide)x\(pixelsHigh) bitmap without pixel data; nothing was rendered."
            case .unsupportedBitmapLayout(let bitsPerPixel, let samplesPerPixel, let isPlanar):
                return
                    "Expected an interleaved 32-bit RGBA bitmap, got bitsPerPixel=\(bitsPerPixel) samplesPerPixel=\(samplesPerPixel) isPlanar=\(isPlanar)."
            }
        }
    }

    /// The window every scene is hosted in.
    ///
    /// It is created, filled, pumped, captured and closed without ever reaching a display.
    /// The overrides below are what make that true; each one is load-bearing.
    private final class OffscreenWindow: NSWindow {
        /// SHOWSTOPPER: without this override AppKit "constrains" the frame onto a real
        /// screen — a probe asked for (-12000, -12000) and got (320, 480), dead centre of the
        /// user's display, visible for 2.4 s. Returning the rect unchanged is the entire
        /// reason this subclass exists. Do not delete it, and do not call super.
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            frameRect
        }

        /// SHOWSTOPPER: a key/main offscreen window is a window that can steal focus. This
        /// pairs with the `.prohibited` activation policy rather than replacing it — key
        /// refusal alone was measured to be insufficient under `.accessory`.
        override var canBecomeKey: Bool { false }

        /// SHOWSTOPPER: see `canBecomeKey`.
        override var canBecomeMain: Bool { false }

        /// SHOWSTOPPER: hosted app code mutates its own window (`WindowChromeConfigurator`
        /// rewrites the style mask and appearance, console panes activate the app). This is
        /// the documented funnel point for `orderFront(_:)`, `orderBack(_:)` and
        /// `orderOut(_:)`, so swallowing everything except `.out` means no scene can put
        /// itself on screen no matter what its `onAppear` does, while `close()` can still
        /// unregister the window normally. `cacheDisplay` was measured to produce a
        /// byte-identical bitmap with no ordering at all, so nothing is lost.
        override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
            guard place == .out else { return }
            super.order(place, relativeTo: otherWin)
        }

        /// SHOWSTOPPER: `orderFrontRegardless()` bypasses the normal ordering funnel, so it
        /// needs its own neutralising override. See `order(_:relativeTo:)`.
        override func orderFrontRegardless() {}
    }

    /// Renders a `UIScene` into a bitmap without a window ever reaching the user's display.
    ///
    /// Known and accepted limitations of this rasterisation path, all measured:
    /// - `cacheDisplay` silently drops `.blur(radius:)` and `.shadow(...)`; Core Animation
    ///   filters are not composited by it. There is no workaround — do not add one.
    /// - A legacy behind-window `NSVisualEffectView` renders as a flat opaque fill because
    ///   there is no desktop behind an offscreen window to sample. That is also a
    ///   determinism win: the user's wallpaper cannot perturb a golden.
    /// - `cacheDisplay` does not rasterise SwiftUI `.glassEffect` at all. That is different
    ///   in kind from the bullet above: the legacy material rasterises as a flat fill, the
    ///   modern one is absent and its area captures fully transparent.
    ///   `overlay.island.recording.os26.png` captures 0.0% opaque and 59.3% fully
    ///   transparent; `menu.idle.os26.png` likewise omits its glass, against 100% opaque
    ///   for the painted `console.sessions.populated.png`. An `os26` scene therefore
    ///   verifies the native branch's own painted content, geometry, control boundaries and
    ///   accessibility tree; it never verifies the material. `scripts/console_shot.sh` is
    ///   the only way to see composited glass.
    /// - `NSColor.controlAccentColor` resolves to the user's system accent colour and no
    ///   environment key overrides it. A golden that shows the system accent will not port
    ///   between machines; SwiftUI's `Color.accentColor` is safe.
    @MainActor
    enum UIHarnessRuntime {
        // MARK: - Timing

        /// One run-loop slice. Fixed at 1 ms so an iteration count reads directly as a
        /// millisecond budget: `UIStep.settle(150)` is 150 iterations, and no caller has to
        /// know the conversion.
        static let pumpSliceSeconds: TimeInterval = 0.001

        /// The settle budget, applied identically before and after the interaction script.
        ///
        /// 150 iterations x 1 ms slice = the 150 ms a probe measured as sufficient for a full
        /// 1280x860 console-sized hierarchy to finish layout and fire `onAppear`. It is a
        /// count, not a deadline, and it is the SAME count on every run: once the run loop
        /// turns, any `.repeatForever` animation makes output time-dependent (200 ms of
        /// pumping between two snapshots of the same scene gave 6/6 unique hashes). A fixed
        /// count is what keeps a golden reproducible. Never make this adaptive, never stop
        /// early on "the tree looks stable", and never derive it from wall-clock time.
        ///
        /// Prefer scenes with no perpetual animation; there is no way to switch one off from
        /// here. `NSAnimationContext.beginGrouping` with duration 0,
        /// `CATransaction.setDisableActions(true)` and `.transaction { $0.disablesAnimations
        /// = true }` were each measured to be complete NO-OPs on this app. Do not cargo-cult
        /// them back in as a fix.
        static let settleIterations = 150

        /// Fixed budget spent after the hierarchy is dropped, so `onDisappear` runs inside
        /// the scene that owns it. Runs strictly after the capture, so it cannot move a
        /// golden byte.
        static let teardownIterations = 30

        /// Upper bound on events consumed by a single drain, so the drain can never spin.
        private static let maximumEventsPerDrain = 64

        // MARK: - Placeholder detection

        /// SwiftUI paints views it cannot render as an opaque `#FFCC00` rectangle with a red
        /// no-entry badge. Any meaningful area of it means the scene is lying about the app.
        private static let placeholderRed = 0xFF
        private static let placeholderGreen = 0xCC
        private static let placeholderBlue = 0x00
        private static let placeholderTolerance = 8
        private static let placeholderMinimumAlpha: UInt8 = 128

        /// Belt and braces on top of `constrainFrameRect`: nowhere near any real display.
        private static let offscreenOrigin = CGPoint(x: -30_000, y: -30_000)

        private static var isProcessPrepared = false

        /// Warnings produced by the most recent scene's interaction script. `withHostedScene`
        /// resets this before hosting, so it is only meaningful to read inside or immediately
        /// after the `body` closure.
        private(set) static var lastInteractionWarnings: [String] = []

        // MARK: - Process setup

        /// Idempotent one-time process setup. Safe to call from every entry point, including
        /// `--list`, and required before anything touches a CoreGraphics window API.
        static func prepareProcess() {
            guard !isProcessPrepared else { return }
            isProcessPrepared = true

            // SHOWSTOPPER: any CoreGraphics window API before `NSApplication.shared` exists
            // and `finishLaunching()` has run SIGABRTs with
            // "Assertion failed: (did_initialize), function CGS_REQUIRE_INIT".
            let application = NSApplication.shared

            // SHOWSTOPPER: `.prohibited` is the only policy that never self-activates —
            // measured 0/24 runs activated, against 20/30 under `.accessory` where
            // `canBecomeKey == false` did not help. It is also what `ConsoleWindowView`'s
            // activation guard tests before it promotes the app to `.regular` and activates.
            // The call RETURNS FALSE even though the policy is applied; discarding that
            // result is deliberate, so do not "fix" it into a precondition.
            _ = application.setActivationPolicy(.prohibited)
            application.finishLaunching()

            // SHOWSTOPPER for the primary signal: NSHostingView reports ZERO accessibility
            // children until the enhanced-user-interface selector runs (measured 1 node
            // before, 23 after).
            let enabled = AXDump.enableEnhancedUserInterface()
            guard !enabled else { return }
            reportToStandardError(
                "accessibility enhanced-user-interface is unavailable; scene dumps will collapse to a single node."
            )
        }

        // MARK: - Hosting

        /// Hosts `scene` in an offscreen window, settles it, runs its interaction script and
        /// hands the hosting view to `body`. The window is closed on every exit path,
        /// including a throw from `body`.
        static func withHostedScene<T>(
            _ scene: UIScene,
            scale: Int,
            _ body: (NSView) throws -> T
        ) rethrows -> T {
            prepareProcess()
            // A previous scene's `onDisappear` can drop the policy back to `.accessory`
            // (`ConsoleWindowView` does exactly that). Correct it BEFORE this scene's `onAppear`
            // can observe it, because `ConsoleWindowView` promotes the app to `.regular` and
            // activates unless it sees `.prohibited`.
            reassertProhibitedActivationPolicy()
            lastInteractionWarnings = []

            let window = makeOffscreenWindow(for: scene)
            let hostingView = makeHostingView(for: scene, scale: scale)
            window.contentView = hostingView
            defer { teardown(window) }

            pump(iterations: settleIterations)
            reassertProhibitedActivationPolicy()
            lastInteractionWarnings = UIInteraction.apply(scene.steps, in: hostingView, window: window)
            pump(iterations: settleIterations)
            return try body(hostingView)
        }

        /// Hosts a mutable flow hierarchy without applying a scene interaction script.
        ///
        /// The setup and teardown deliberately share the scene path above. A flow owns every
        /// pump after the initial settle because its checkpoints must observe intermediate states.
        static func withLiveScene<T>(
            size: CGSize,
            colorScheme: ColorScheme,
            scale: Int,
            build: @MainActor () -> AnyView,
            _ body: (NSView, NSWindow) throws -> T
        ) rethrows -> T {
            prepareProcess()
            reassertProhibitedActivationPolicy()
            lastInteractionWarnings = []

            let window = makeOffscreenWindow(size: size, colorScheme: colorScheme)
            let hostingView = makeHostingView(
                size: size,
                colorScheme: colorScheme,
                scale: scale,
                build: build
            )
            window.contentView = hostingView
            defer { teardown(window) }

            pump(iterations: settleIterations)
            reassertProhibitedActivationPolicy()
            return try body(hostingView, window)
        }

        /// Adds best-effort interaction diagnostics while keeping warning ownership in the runtime.
        static func appendInteractionWarnings(_ warnings: [String]) {
            lastInteractionWarnings.append(contentsOf: warnings)
        }

        /// Drops the hierarchy and lets its `onDisappear` run inside *this* scene's teardown
        /// rather than leaking into the next scene's settle. Pumping here cannot affect a
        /// golden: the capture has already happened by the time this runs.
        private static func teardown(_ window: NSWindow) {
            window.contentView = nil
            window.close()
            pump(iterations: teardownIterations)
            reassertProhibitedActivationPolicy()
        }

        private static func makeOffscreenWindow(for scene: UIScene) -> OffscreenWindow {
            makeOffscreenWindow(size: scene.size, colorScheme: scene.colorScheme)
        }

        private static func makeOffscreenWindow(size: CGSize, colorScheme: ColorScheme) -> OffscreenWindow {
            // SHOWSTOPPER: `[.borderless]` only. Under `.titled` the titlebar folds into the
            // content view after the first run-loop turn (1280x860 becomes 1280x892), which
            // shifts every golden coordinate by 32 pt.
            // `defer: false` is load-bearing, not a default: it creates the window device
            // immediately, which is what gives the window a real `windowNumber` for
            // `UIInteraction`'s synthetic mouse events to be matched against.
            let window = OffscreenWindow(
                contentRect: NSRect(origin: offscreenOrigin, size: size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.collectionBehavior = [.stationary, .ignoresCycle, .transient]
            // Appearance is forced on BOTH the window and the hosting view: SwiftUI ignores
            // `NSApp.appearance`, and the window's own appearance is overwritten by hosted app
            // code (`WindowChromeConfigurator` sets `.vibrantDark`), so the view-level pin is
            // the one that actually decides how the scene renders.
            window.appearance = appearance(for: colorScheme)
            return window
        }

        private static func makeHostingView(for scene: UIScene, scale: Int) -> NSView {
            makeHostingView(
                size: scene.size,
                colorScheme: scene.colorScheme,
                scale: scale,
                build: scene.build
            )
        }

        private static func makeHostingView(
            size: CGSize,
            colorScheme: ColorScheme,
            scale: Int,
            build: @MainActor () -> AnyView
        ) -> NSView {
            let rootView = build()
                .environment(\.colorScheme, colorScheme)
                // Pinning displayScale keeps pixel snapping independent of the developer's
                // monitor: `window.backingScaleFactor` still reads 2.0 while fully offscreen,
                // so an unpinned hierarchy would lay out differently on a 1x machine.
                .environment(\.displayScale, CGFloat(max(1, scale)))
                .environment(\.calendar, RenderOverrides.calendar ?? Calendar.current)
                .environment(\.locale, RenderOverrides.locale ?? Locale.current)
                .environment(\.timeZone, RenderOverrides.timeZone ?? TimeZone.current)
                .frame(width: size.width, height: size.height)
            let hostingView = NSHostingView(rootView: AnyView(rootView))
            hostingView.appearance = appearance(for: colorScheme)
            hostingView.frame = NSRect(origin: .zero, size: size)
            return hostingView
        }

        private static func appearance(for colorScheme: ColorScheme) -> NSAppearance? {
            NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        }

        /// SHOWSTOPPER backstop: hosted app code can promote the process to `.regular` and
        /// activate (`ConsoleWindowView.onAppear`). Its activation guard observes the current
        /// `.prohibited` policy, so the policy must never be allowed to drift back.
        private static func reassertProhibitedActivationPolicy() {
            guard NSApp.activationPolicy() != .prohibited else { return }
            _ = NSApp.setActivationPolicy(.prohibited)
            reportToStandardError("a scene changed the activation policy; forced it back to .prohibited.")
        }

        // MARK: - Run loop

        /// Turns the run loop a fixed number of times.
        ///
        /// Each iteration is one `RunLoop.run(mode:before:)` slice plus a full drain of the
        /// posted event queue. Both halves are required: `onAppear` never fires without a
        /// pumped run loop, and posted events are never delivered without the drain.
        static func pump(iterations: Int) {
            guard iterations > 0 else { return }
            for _ in 0..<iterations {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(pumpSliceSeconds))
                drainPostedEvents()
            }
        }

        /// Converts a millisecond budget into the iteration count that spends it, so callers
        /// never have to hard-code the slice length.
        static func pumpIterations(forMilliseconds milliseconds: Int) -> Int {
            let sliceMilliseconds = max(1.0, pumpSliceSeconds * 1000.0)
            return max(1, Int((Double(milliseconds) / sliceMilliseconds).rounded()))
        }

        /// SHOWSTOPPER for synthetic interaction: `NSApp.postEvent` is only delivered by an
        /// `NSApp.nextEvent` drain. `Thread.sleep` delivers nothing and `RunLoop.run(until:)`
        /// ALONE also delivers nothing — without this, a queued mouseUp never reaches the
        /// tracking loop that is waiting for it and the next click wedges the process.
        /// `Date.distantPast` polls, so no iteration of this loop can ever block.
        private static func drainPostedEvents() {
            // `NSApp` is an implicitly unwrapped `NSApplication!` and is nil until
            // `prepareProcess()` touches `NSApplication.shared`. The fixture settle helper
            // pumps from `swift test`, where no application object exists and no event queue
            // can, so dereferencing it there crashed the whole test binary with signal 5.
            // Nothing to drain is the correct answer, not a precondition.
            guard let application = NSApp else { return }
            for _ in 0..<maximumEventsPerDrain {
                guard
                    let event = application.nextEvent(
                        matching: .any,
                        until: Date.distantPast,
                        inMode: .default,
                        dequeue: true
                    )
                else {
                    return
                }
                application.sendEvent(event)
            }
        }

        // MARK: - Rasterisation

        /// Rasterises `view` at `scale` and measures the two "is this render broken?" signals
        /// in a single pass over the bitmap.
        ///
        /// `UICapture.width`/`height` are PIXEL dimensions and match the PNG's own IHDR; the
        /// logical point size is `width / scale`.
        static func capture(_ view: NSView, scale: Int) throws -> UICapture {
            let pointSize = view.bounds.size
            let clampedScale = max(1, scale)
            let pixelsWide = Int((pointSize.width * CGFloat(clampedScale)).rounded())
            let pixelsHigh = Int((pointSize.height * CGFloat(clampedScale)).rounded())
            guard pixelsWide > 0, pixelsHigh > 0 else {
                throw UIHarnessRuntimeError.emptyViewBounds(pixelsWide: pixelsWide, pixelsHigh: pixelsHigh)
            }
            guard let rep = UIPNG.makeBitmap(pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, pointSize: pointSize)
            else {
                throw UIHarnessRuntimeError.bitmapAllocationFailed(pixelsWide: pixelsWide, pixelsHigh: pixelsHigh)
            }

            try draw(view, into: rep)
            let statistics = try measure(rep)
            let png = try UIPNG.encode(rep)
            return UICapture(
                width: pixelsWide,
                height: pixelsHigh,
                png: png,
                sha256: UIPNG.sha256(png),
                dominantColorFraction: statistics.dominantColorFraction,
                placeholderFraction: statistics.placeholderFraction
            )
        }

        private static func draw(_ view: NSView, into rep: NSBitmapImageRep) throws {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            if let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = context
                pinRasterisationFlags(on: context)
            }
            // SHOWSTOPPER: `cacheDisplay(in:to:)` into a bitmap we own, never `ImageRenderer`.
            // ImageRenderer stubs EVERY NSViewRepresentable and AppKit-backed control with an
            // opaque #FFCC00 rectangle — confirmed for this repo's own FrostedGlassBackground
            // and for a plain ProgressView — so it cannot render this app at all.
            view.cacheDisplay(in: view.bounds, to: rep)
            guard rep.bitmapData != nil else {
                throw UIHarnessRuntimeError.captureProducedNoPixels(
                    pixelsWide: rep.pixelsWide,
                    pixelsHigh: rep.pixelsHigh
                )
            }
        }

        /// Pins the rasterisation levers instead of inheriting whatever the process defaults
        /// happen to be. Font smoothing is a real determinism lever: toggling it moved 2083
        /// pixels with a max channel delta of 121 on this app. The RGBA8 destination already
        /// declines subpixel smoothing, and these setters make that a stated intent rather
        /// than a happy accident of the bitmap format.
        private static func pinRasterisationFlags(on context: NSGraphicsContext) {
            context.shouldAntialias = true
            let cgContext = context.cgContext
            cgContext.setShouldSmoothFonts(false)
            cgContext.setAllowsFontSmoothing(false)
            cgContext.setShouldAntialias(true)
            cgContext.setAllowsAntialiasing(true)
        }

        // MARK: - Broken-render detection

        private struct PixelStatistics {
            let dominantColorFraction: Double
            let placeholderFraction: Double
        }

        private static func measure(_ rep: NSBitmapImageRep) throws -> PixelStatistics {
            try validateLayout(of: rep)
            guard let base = rep.bitmapData, rep.pixelsWide > 0, rep.pixelsHigh > 0 else {
                throw UIHarnessRuntimeError.captureProducedNoPixels(
                    pixelsWide: rep.pixelsWide,
                    pixelsHigh: rep.pixelsHigh
                )
            }
            return scan(base, width: rep.pixelsWide, height: rep.pixelsHigh, bytesPerRow: rep.bytesPerRow)
        }

        private static func validateLayout(of rep: NSBitmapImageRep) throws {
            guard rep.bitsPerPixel == 32, rep.samplesPerPixel == 4, !rep.isPlanar else {
                throw UIHarnessRuntimeError.unsupportedBitmapLayout(
                    bitsPerPixel: rep.bitsPerPixel,
                    samplesPerPixel: rep.samplesPerPixel,
                    isPlanar: rep.isPlanar
                )
            }
        }

        /// Single pass over the raw bytes. `bytesPerRow` is read from the rep rather than
        /// assumed to be `width * 4`, because the allocator is allowed to pad rows.
        ///
        /// Bitmap format 0 means interleaved, premultiplied, alpha last, so the byte order is
        /// R, G, B, A.
        private static func scan(
            _ base: UnsafeMutablePointer<UInt8>,
            width: Int,
            height: Int,
            bytesPerRow: Int
        ) -> PixelStatistics {
            var histogram: [UInt32: Int] = [:]
            histogram.reserveCapacity(1 << 15)
            var dominantCount = 0
            var placeholderPixels = 0

            for row in 0..<height {
                var offset = row * bytesPerRow
                for _ in 0..<width {
                    let red = base[offset]
                    let green = base[offset + 1]
                    let blue = base[offset + 2]
                    let alpha = base[offset + 3]
                    let packed = UInt32(red) << 24 | UInt32(green) << 16 | UInt32(blue) << 8 | UInt32(alpha)
                    let count = histogram[packed, default: 0] + 1
                    histogram[packed] = count
                    if count > dominantCount { dominantCount = count }
                    if isPlaceholder(red: red, green: green, blue: blue, alpha: alpha) { placeholderPixels += 1 }
                    offset += 4
                }
            }

            let totalPixels = Double(width * height)
            return PixelStatistics(
                dominantColorFraction: Double(dominantCount) / totalPixels,
                placeholderFraction: Double(placeholderPixels) / totalPixels
            )
        }

        private static func isPlaceholder(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) -> Bool {
            guard alpha >= placeholderMinimumAlpha else { return false }
            return withinTolerance(red, of: placeholderRed)
                && withinTolerance(green, of: placeholderGreen)
                && withinTolerance(blue, of: placeholderBlue)
        }

        private static func withinTolerance(_ sample: UInt8, of reference: Int) -> Bool {
            abs(Int(sample) - reference) <= placeholderTolerance
        }

        // MARK: - Diagnostics

        /// stdout belongs to the machine-readable manifest, so every diagnostic goes to
        /// stderr with the harness prefix.
        private static func reportToStandardError(_ message: String) {
            fputs("ui-harness: \(message)\n", stderr)
        }
    }

#endif
