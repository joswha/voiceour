import AppKit
import Testing

@testable import Voiceour

/// The display arithmetic is checked against what AppKit actually reported for this Mac's
/// built-in 16-inch panel at its default scaling, then against every malformed report.
struct RecordingOverlayDisplayTests {
    /// What AppKit reports for a notched display's top edge.
    struct TopReport: Sendable, CustomTestStringConvertible {
        var testDescription: String
        var safeAreaTop: CGFloat
        var leftArea: CGRect?
        var rightArea: CGRect?
    }

    struct Band: Sendable, CustomTestStringConvertible {
        var testDescription: String
        var frame: CGRect
        var visibleFrame: CGRect
        var housing: CGRect?
        var height: CGFloat
    }

    private static let builtIn = CGRect(x: 0, y: 0, width: 1_728, height: 1_117)
    private static let leftArea = CGRect(x: 0, y: 1_085, width: 771.5, height: 32)
    private static let rightArea = CGRect(x: 956.5, y: 1_085, width: 771.5, height: 32)
    private static let housing = CGRect(x: 771.5, y: 1_085, width: 185, height: 32)

    @Test func theHousingIsTheGapBetweenTheTwoUnobscuredTopAreas() {
        let housing = OverlayDisplayGeometry.housing(
            frame: Self.builtIn,
            safeAreaTop: 32,
            leftArea: Self.leftArea,
            rightArea: Self.rightArea
        )
        #expect(housing == Self.housing)
    }

    /// AppKit reports both areas in global coordinates, so a notched display that is not the
    /// primary one needs no origin arithmetic.
    @Test func theHousingStaysInGlobalCoordinatesOnASecondaryDisplay() {
        let frame = CGRect(x: -1_728, y: 200, width: 1_728, height: 1_117)
        let housing = OverlayDisplayGeometry.housing(
            frame: frame,
            safeAreaTop: 32,
            leftArea: CGRect(x: -1_728, y: 1_285, width: 771.5, height: 32),
            rightArea: CGRect(x: -771.5, y: 1_285, width: 771.5, height: 32)
        )
        #expect(housing == CGRect(x: -956.5, y: 1_285, width: 185, height: 32))
    }

    static let malformedTops: [TopReport] = [
        TopReport(testDescription: "no top inset", safeAreaTop: 0, leftArea: leftArea, rightArea: rightArea),
        TopReport(testDescription: "a negative top inset", safeAreaTop: -32, leftArea: leftArea, rightArea: rightArea),
        TopReport(testDescription: "no left area", safeAreaTop: 32, leftArea: nil, rightArea: rightArea),
        TopReport(testDescription: "no right area", safeAreaTop: 32, leftArea: leftArea, rightArea: nil),
        TopReport(testDescription: "neither area", safeAreaTop: 32, leftArea: nil, rightArea: nil),
        TopReport(
            testDescription: "areas that meet",
            safeAreaTop: 32,
            leftArea: CGRect(x: 0, y: 1_085, width: 864, height: 32),
            rightArea: CGRect(x: 864, y: 1_085, width: 864, height: 32)
        ),
        TopReport(
            testDescription: "areas that overlap",
            safeAreaTop: 32,
            leftArea: CGRect(x: 0, y: 1_085, width: 900, height: 32),
            rightArea: CGRect(x: 800, y: 1_085, width: 928, height: 32)
        ),
        TopReport(
            testDescription: "a gap half the display wide",
            safeAreaTop: 32,
            leftArea: CGRect(x: 0, y: 1_085, width: 432, height: 32),
            rightArea: CGRect(x: 1_296, y: 1_085, width: 432, height: 32)
        ),
    ]

    @Test(arguments: RecordingOverlayDisplayTests.malformedTops)
    func thereIsNoHousingWithoutAPlausibleGap(_ report: TopReport) {
        let housing = OverlayDisplayGeometry.housing(
            frame: Self.builtIn,
            safeAreaTop: report.safeAreaTop,
            leftArea: report.leftArea,
            rightArea: report.rightArea
        )
        #expect(housing == nil)
    }

    static let bands: [Band] = [
        Band(
            testDescription: "notched, menu bar showing",
            frame: builtIn,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_728, height: 1_084),
            housing: housing,
            height: 33
        ),
        Band(
            testDescription: "notched, menu bar hidden",
            frame: builtIn,
            visibleFrame: builtIn,
            housing: housing,
            height: 33
        ),
        Band(
            testDescription: "notched, menu bar deeper than the housing",
            frame: builtIn,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_728, height: 1_080),
            housing: housing,
            height: 37
        ),
        Band(
            testDescription: "notchless, 24 pt menu bar over a Dock",
            frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            visibleFrame: CGRect(x: 0, y: 70, width: 1_512, height: 888),
            housing: nil,
            height: 24
        ),
        Band(
            testDescription: "notchless, no menu bar on this display",
            frame: CGRect(x: 1_728, y: -323, width: 2_560, height: 1_440),
            visibleFrame: CGRect(x: 1_728, y: -323, width: 2_560, height: 1_440),
            housing: nil,
            height: 0
        ),
    ]

    @Test(arguments: RecordingOverlayDisplayTests.bands)
    func theBandIsTheMenuBarAndNeverShallowerThanTheHousing(_ band: Band) {
        let height = OverlayDisplayGeometry.bandHeight(
            frame: band.frame,
            visibleFrame: band.visibleFrame,
            housing: band.housing
        )
        #expect(height == band.height)
    }

    @Test func theFixturesAreTheDisplaysTheyName() {
        let notchless = OverlayDisplay.fixtureNotchless
        #expect(notchless.frame == CGRect(x: 0, y: 0, width: 1_512, height: 982))
        #expect(notchless.visibleFrame.maxY == notchless.frame.maxY - 24)
        #expect(notchless.housing == nil)
        #expect(!notchless.hasNotch)

        let notch = OverlayDisplay.fixtureNotch
        #expect(notch.frame == Self.builtIn)
        #expect(notch.housing == Self.housing)
        #expect(notch.hasNotch)

        let wide = OverlayDisplay.fixtureWideNotch
        #expect(wide.frame == CGRect(x: 0, y: 0, width: 2_056, height: 1_329))
        #expect(wide.housing?.size == CGSize(width: 220, height: 38))
        #expect(wide.hasNotch)

        let bands: [CGFloat] = [24, 33, 39]
        for (display, band) in zip([notchless, notch, wide], bands) {
            let derived = OverlayDisplayGeometry.bandHeight(
                frame: display.frame,
                visibleFrame: display.visibleFrame,
                housing: display.housing
            )
            #expect(display.bandHeight == band)
            #expect(derived == band)
            #expect(display.maximumFramesPerSecond == 120)
            #expect(!display.isMirrored)
            if let housing = display.housing {
                #expect(housing.midX == display.frame.midX)
                #expect(housing.maxY == display.frame.maxY)
            }
        }
        #expect(Set([notchless.id, notch.id, wide.id]).count == 3)
    }

    /// A mirror set shows the same pixels on a panel without the housing.
    @Test func aMirroredNotchedDisplayGetsTheIsland() {
        var mirrored = OverlayDisplay.fixtureNotch
        mirrored.isMirrored = true
        #expect(mirrored.housing != nil)
        #expect(!mirrored.hasNotch)
    }

    /// The harness's determinism rests on the pin replacing the live read wholesale. The live
    /// read itself is whatever this Mac has attached, so only its consistency is checked.
    @Test(.enabled(if: !NSScreen.screens.isEmpty, "the live read needs an attached display"))
    @MainActor
    func aPinnedDisplayReplacesTheLiveScreenRead() throws {
        let screen = try #require(NSScreen.screens.first)
        let saved = RenderOverrides.overlayDisplay
        defer { RenderOverrides.overlayDisplay = saved }

        RenderOverrides.overlayDisplay = nil
        let live = OverlayDisplayGeometry.display(for: screen)
        #expect(live.frame == screen.frame)
        #expect(live.visibleFrame == screen.visibleFrame)
        #expect(live.maximumFramesPerSecond == screen.maximumFramesPerSecond)
        let band = OverlayDisplayGeometry.bandHeight(
            frame: live.frame,
            visibleFrame: live.visibleFrame,
            housing: live.housing
        )
        #expect(live.bandHeight == band)
        if let housing = live.housing {
            #expect(housing.maxY == live.frame.maxY)
            #expect(housing.minX > live.frame.minX)
            #expect(housing.maxX < live.frame.maxX)
        }

        RenderOverrides.overlayDisplay = .fixtureWideNotch
        #expect(OverlayDisplayGeometry.display(for: screen) == .fixtureWideNotch)
    }
}
