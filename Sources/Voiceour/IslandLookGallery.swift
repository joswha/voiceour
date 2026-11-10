import SwiftUI
import VoiceCore

/// The Island page's looks: every look as a card showing the body it draws, the card of the
/// look in force lit, and Surprise Me.
///
/// Derived, never stored: the card whose look matches is selected, and none is for Custom,
/// which the showroom's look mark names instead. Each card is a button whose accessibility
/// label is the look's name and which carries the selected trait while its look is in force;
/// the cards share the `island.look` container.
///
/// The thumbnails are stills from `IslandLookThumbnails`, warmed when the page appears, one per
/// main-actor turn, so no card renders a body inside a view update and no card runs a display
/// link. Until they land a card shows its empty well.
struct IslandLookGallery: View, Equatable {
    let look: IslandLook?
    let increasedContrast: Bool
    let editor: IslandGarageEditor
    let coordinator: DictationCoordinator
    @Environment(\.undoManager) private var undoManager

    /// The stills on show, filled once the warm-up has cached them all.
    @State private var thumbnails: [IslandLook: CGImage] = [:]
    /// Surprise Me is replayable: one seed per page lifetime — the mercury seed seam when the
    /// harness pins it, random otherwise — taken on the first press, and a counter each press
    /// advances.
    @State private var surpriseSeed: UInt64?
    @State private var surpriseDraw: UInt64 = 0

    /// Four looks to a row, in `IslandLook`'s order.
    private static let columns = 4
    private static let rows: [[IslandLook]] = stride(
        from: 0,
        to: IslandLook.allCases.count,
        by: columns
    ).map { start in
        Array(IslandLook.allCases[start..<min(start + columns, IslandLook.allCases.count)])
    }

    init(
        look: IslandLook?,
        increasedContrast: Bool,
        editor: IslandGarageEditor,
        coordinator: DictationCoordinator
    ) {
        self.look = look
        self.increasedContrast = increasedContrast
        self.editor = editor
        self.coordinator = coordinator
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.look == rhs.look && lhs.increasedContrast == rhs.increasedContrast
            && lhs.editor === rhs.editor && lhs.coordinator === rhs.coordinator
    }

    var body: some View {
        Kit.Island {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.md) {
                Kit.SectionTitle("Look") {
                    Kit.ActionButton("Surprise Me", systemImage: "dice") { surprise() }
                        .help("Draws a random look from every option's range.")
                        .accessibilityIdentifier("island.look.surprise")
                }

                Grid(
                    horizontalSpacing: VoiceourMetrics.Space.sm,
                    verticalSpacing: VoiceourMetrics.Space.sm
                ) {
                    ForEach(Self.rows, id: \.self) { row in
                        GridRow {
                            ForEach(row, id: \.self) { card in
                                IslandLookCard(
                                    look: card,
                                    image: thumbnails[card],
                                    isSelected: card == look,
                                    choose: { choose(card) }
                                )
                                .equatable()
                            }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Look")
                .accessibilityIdentifier("island.look")

                IslandCaption("Choosing a look replaces every option below; ⌘Z undoes it.")
            }
        }
        .task(id: increasedContrast) {
            await loadThumbnails()
        }
    }

    private func loadThumbnails() async {
        let increasedContrast = increasedContrast
        await IslandLookThumbnails.warm(increasedContrast: increasedContrast)
        guard !Task.isCancelled else { return }
        var images: [IslandLook: CGImage] = [:]
        for look in IslandLook.allCases {
            images[look] = IslandLookThumbnails.image(for: look, increasedContrast: increasedContrast)
        }
        thumbnails = images
    }

    private func choose(_ look: IslandLook) {
        guard look != IslandLook.matching(coordinator.effectiveIsland) else { return }
        editor.apply("Choose Look", undoManager: undoManager) { $0 = look.appearance }
    }

    private func surprise() {
        let seed = surpriseSeed ?? RenderOverrides.mercurySeed ?? UInt64.random(in: .min ... .max)
        surpriseSeed = seed
        let next = IslandAppearance.surprise(
            seed: seed,
            draw: surpriseDraw,
            avoiding: coordinator.effectiveIsland
        )
        surpriseDraw += 1
        editor.apply("Surprise Me", undoManager: undoManager) { $0 = next }
    }
}

/// One look: its still in a dark well over its name, lit while the look is in force.
///
/// One accessibility element, a button named for the look, so the still and the name are not
/// two stops for one choice.
private struct IslandLookCard: View, Equatable {
    let look: IslandLook
    let image: CGImage?
    let isSelected: Bool
    let choose: @MainActor () -> Void

    /// The well's height: the island canvas's 196:34 aspect at a card's width, with room
    /// around it.
    private static let wellHeight: CGFloat = 40

    /// Leaves the closure out: it only names this card's look, which `look` already compares.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.look == rhs.look && lhs.image === rhs.image && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        Button {
            choose()
        } label: {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.xs) {
                well
                Text(look.displayName)
                    .roleStyle(.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(VoiceourMetrics.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(Kit.RowButtonStyle(isSelected: isSelected))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(look.displayName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var well: some View {
        let shape = RoundedRectangle(cornerRadius: Kit.Metrics.rowRadius, style: .continuous)
        return ZStack {
            shape.fill(VoiceourPalette.Ink.well)
            if let image {
                Image(decorative: image, scale: MercuryMetrics.rasterScale)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(.horizontal, VoiceourMetrics.Space.sm)
                    .padding(.vertical, VoiceourMetrics.Space.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.wellHeight)
        .accessibilityHidden(true)
    }
}
