import AppKit
import Foundation
import Testing

@testable import Voiceour

/// The transcript's selection-to-TEACH affordance hangs off one AppKit primitive.
/// The offscreen UI harness can seed a selection and prove the bar renders, but it
/// has no drag/selection step, so the delivery contract itself is only pinned here.
@MainActor
struct TranscriptSelectionReportingTests {
    private static let transcript = "If you need to test anything, use the Ubun to that box, CSSH conflict."

    private func makeView(
        identity: UUID = UUID(),
        onSelectionChange: @escaping (String?) -> Void
    ) -> FixTeachTextView {
        let view = FixTeachTextView()
        view.isEditable = false
        view.isSelectable = true
        view.onSelectionChange = onSelectionChange
        view.install(
            identity: identity,
            attributedText: NSAttributedString(string: Self.transcript),
            selectionSurface: ""
        )
        return view
    }

    /// Reports land on the next main-queue turn so the callback never mutates
    /// SwiftUI state inside a view update.
    private func drain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func range(of substring: String) -> NSRange {
        (Self.transcript as NSString).range(of: substring)
    }

    @Test func completedSelectionReportsTheTrimmedSurface() async {
        var reported: [String?] = []
        let view = makeView { reported.append($0) }
        await drain()
        reported.removeAll()

        view.setSelectedRange(range(of: "the Ubun to that box"), affinity: .downstream, stillSelecting: false)
        await drain()

        #expect(reported == ["the Ubun to that box"])
    }

    /// A drag walks the range across many words. Publishing each intermediate
    /// range would flicker the bar's surface through every word the pointer
    /// crosses, so only the completed selection is reported.
    @Test func intermediateDragRangesAreNotReported() async {
        var reported: [String?] = []
        let view = makeView { reported.append($0) }
        await drain()
        reported.removeAll()

        view.setSelectedRange(range(of: "the"), affinity: .downstream, stillSelecting: true)
        view.setSelectedRange(range(of: "the Ubun"), affinity: .downstream, stillSelecting: true)
        await drain()
        #expect(reported.isEmpty)

        view.setSelectedRange(range(of: "the Ubun to"), affinity: .downstream, stillSelecting: false)
        await drain()
        #expect(reported == ["the Ubun to"])
    }

    @Test func collapsingTheSelectionReportsNil() async {
        var reported: [String?] = []
        let view = makeView { reported.append($0) }
        view.setSelectedRange(range(of: "conflict"), affinity: .downstream, stillSelecting: false)
        await drain()
        reported.removeAll()

        view.setSelectedRange(NSRange(location: 0, length: 0), affinity: .downstream, stillSelecting: false)
        await drain()

        #expect(reported == [String?.none])
    }

    /// Punctuation the user swept up with a double-click would otherwise become
    /// part of the taught surface.
    @Test func trailingPunctuationIsTrimmedFromTheSurface() async {
        var reported: [String?] = []
        let view = makeView { reported.append($0) }
        await drain()
        reported.removeAll()

        view.setSelectedRange(range(of: "that box,"), affinity: .downstream, stillSelecting: false)
        await drain()

        #expect(reported == ["that box"])
    }

    /// Two sessions can hold byte-identical text. SwiftUI reuses the text view
    /// across them, so a reinstall keyed only on the string would leave the
    /// previous session's range live and let a right-click teach it.
    @Test func reinstallingUnderANewIdentityClearsTheInheritedSelection() async {
        var reported: [String?] = []
        let view = makeView { reported.append($0) }
        view.setSelectedRange(range(of: "CSSH"), affinity: .downstream, stillSelecting: false)
        await drain()
        #expect(reported.last == "CSSH")
        reported.removeAll()

        let next = UUID()
        view.install(
            identity: next,
            attributedText: NSAttributedString(string: Self.transcript),
            selectionSurface: ""
        )
        await drain()

        #expect(view.installedIdentity == next)
        #expect(view.selectedRange.length == 0)
        #expect(reported == [String?.none])
    }

    /// The harness has no selection step, so scenes seed one through
    /// `RenderOverrides`. That seed must run the same reporting path a real
    /// selection does, or the golden would prove nothing about production.
    @Test func seededSelectionSurfaceReportsThroughTheProductionPath() async {
        var reported: [String?] = []
        let view = FixTeachTextView()
        view.isSelectable = true
        view.onSelectionChange = { reported.append($0) }
        view.install(
            identity: UUID(),
            attributedText: NSAttributedString(string: Self.transcript),
            selectionSurface: "Ubun to that box"
        )
        await drain()

        #expect(reported.last == "Ubun to that box")
    }
}
