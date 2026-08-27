import CoreGraphics
import Foundation
import VoiceCore
import VoiceMac

// Production code, never gated behind `UI_HARNESS`.
//
// Named for what it is rather than for its main consumer. The offscreen harness
// is what *sets* these, but many production files *read* them, so calling the
// type `UIHarnessSeams` invited exactly the mistake this gate has to avoid:
// gating or deleting it alongside `UIHarness/`, which does not compile.
//

/// Render-time overrides consumed by a small number of production views so the
/// harness can produce byte-stable, machine-portable goldens.
///
/// The invariant is about its defaults: every field's declared default is nil or false,
/// and with all of them at that default the app behaves exactly as it would if this type
/// did not exist. How a set seam is read follows what it substitutes — `override ?? realValue`
/// for a value, `if let` for a wholesale replacement, a plain boolean branch for
/// `forceLegacyGlass` — never a branch that exists only to make a golden pass.
/// Read and written on the main thread only, like the views that consume them.
enum RenderOverrides {
    /// Pins "now" for deterministic fixtures that render date-relative state.
    /// Without it, labels derived from the current day can change at midnight.
    static var now: Date?

    /// Pins the Foundation context used to bucket and format fixture dates and
    /// numbers. These are separate seams because production formatters read each
    /// independently, and because SwiftUI exposes all three as environment values.
    static var calendar: Calendar?
    static var locale: Locale?
    static var timeZone: TimeZone?

    /// Pins the permission answers the System and Diagnostics panes display, so
    /// a golden does not encode whichever privacy grants this Mac happens to
    /// have. Also lets the harness render both the granted and the denied
    /// treatments, which real TCC state can only ever show one of.
    static var permissions: PermissionsChecking?

    /// Pins the storage paths the Diagnostics pane prints, so a committed
    /// fixture never contains the developer's home directory.
    static var settingsPath: String?
    static var recentSessionsPath: String?
    static var dictationStatsPath: String?

    /// Writable harness mirrors for the SDK's get-only accessibility
    /// environment values. They stay nil in production; production views
    /// resolve each one as `override ?? <real environment value>`.
    static var reduceTransparency: Bool?
    static var reduceMotion: Bool?
    static var differentiateWithoutColor: Bool?
    static var increasedContrast: Bool?

    /// Seeds one readable transcript substring as the current selection. A
    /// surface, rather than an NSRange, keeps catalog scenes independent of
    /// fixture offsets while production falls back to no seeded selection.
    static var transcriptSelectionSurface: String?

    /// Renders History as a reader who has closed the open transcript sees it —
    /// nothing open, nothing dimmed. The tab otherwise opens its newest transcript
    /// on arrival, which no scene step can undo: deselection is a click on the
    /// form's own background, and the harness can only press accessibility nodes.
    /// Production reads this as `false`, which is the same first-visit path a real
    /// launch takes.
    static var historyStartsDeselected = false

    /// Pins History's opening app filter. The filter is engaged through an
    /// `NSMenu` popup, which the offscreen window can never order front, so a
    /// scene states the filtered list rather than driving the control. Production
    /// reads this as nil, which is every app.
    static var historyInitialAppFilter: String?

    /// Pins History's teach editor open, aimed at this surface. Teaching is
    /// reached by Command-T or the transcript's own `Fix / Teach` item, and
    /// neither can be delivered to a window that never becomes key, so a scene
    /// states what the editor holds rather than performing the gesture that
    /// opens it. Production reads this as nil, which is no editor.
    static var historyTeachSurface: String?

    /// Pins the installed-app catalog so a golden never encodes which apps the
    /// rendering Mac happens to have. Non-nil replaces the catalog wholesale: an
    /// absent key means "not installed", which falls back to the letter monogram
    /// and the persisted snapshot name. Production reads this as nil, which is
    /// the live LaunchServices lookup.
    static var installedApps: [String: InstalledApp]?

    /// Pins the input-device list the Settings microphone picker offers, so a
    /// golden never encodes which microphones the rendering Mac happens to have.
    /// Non-nil replaces the CoreAudio enumeration wholesale. Production reads
    /// this as nil, which is the live HAL read.
    static var availableMicrophones: [CoreAudioInputDevice.AvailableMicrophone]?

    /// Forces the painted macOS 14 glass path on a newer runtime. Production
    /// follows availability normally; the harness pins this to true below.
    static var forceLegacyGlass = false

    /// Harness-only ledger populated by `.roleStyle(_:)`. Nil in production, so
    /// shipping views do not install geometry probes or allocate samples.
    static var textRoleRecorder: TextRoleRecorder?

}

// The seam's payload types. Ungated for the same reason as the seams themselves:
// `DesignTokenInstrumentation` is on the canonical `.roleStyle(_:)` path and
// `RenderOverrides.textRoleRecorder` is typed by the recorder, so gating these
// would break the app build. Nothing production reads them unless the harness
// installs a recorder, which it only does while a scene is hosted.

/// One resolved text token observed while the harness builds a scene.
///
/// Colours are opaque sRGB values. `frame` uses the same window-local, top-left
/// coordinate space as `AXNode.frame`, so lint can join the token back to the
/// user-readable accessibility node without relying on view traversal order.
struct TextRoleSample: Equatable {
    let role: String
    let foreground: (r: Double, g: Double, b: Double)
    let ground: (r: Double, g: Double, b: Double)
    let pointSize: CGFloat
    let isBold: Bool
    let frame: CGRect

    static func == (left: Self, right: Self) -> Bool {
        left.role == right.role
            && left.foreground.r == right.foreground.r
            && left.foreground.g == right.foreground.g
            && left.foreground.b == right.foreground.b
            && left.ground.r == right.ground.r
            && left.ground.g == right.ground.g
            && left.ground.b == right.ground.b
            && left.pointSize == right.pointSize
            && left.isBold == right.isBold
            && left.frame == right.frame
    }
}

/// Harness-only sink for the latest geometry published by each mounted
/// `.roleStyle(_:)` view. The process-wide seam owns this recorder only while a
/// scene is hosted; production never constructs one.
final class TextRoleRecorder {
    private var samplesByID: [UUID: TextRoleSample] = [:]

    func record(_ sample: TextRoleSample, id: UUID) {
        samplesByID[id] = sample
    }

    func remove(id: UUID) {
        samplesByID.removeValue(forKey: id)
    }

    var samples: [TextRoleSample] {
        Array(samplesByID.values)
    }
}

/// A `DateFormatter` with the three seams the harness pins already applied, in
/// order: calendar, locale, time zone. Those three are the whole of what keeps
/// a golden machine-independent, so every date formatter in the app has to
/// resolve all three the same way — one that misses a seam bakes this Mac's own
/// settings into a committed fixture. Always a fresh instance: `DateFormatter`
/// is mutable and each call site sets its own format on top.
enum RenderFormatters {
    static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = RenderOverrides.calendar ?? Calendar.current
        formatter.locale = RenderOverrides.locale ?? Locale.current
        formatter.timeZone = RenderOverrides.timeZone ?? TimeZone.current
        return formatter
    }
}
