import AppKit
import Combine
import SwiftUI
import VoiceCore

// MARK: - Showroom poses

/// The states the Island showroom can hold the body in: what the island does during a
/// dictation, shown without one.
///
/// View state only, never saved. The showroom opens on Speaking unless
/// `RenderOverrides.islandShowroomPose` pins another pose: the pose is picked from a pop-up
/// menu, which the offscreen harness window can never open, so a scene states its pose rather
/// than choosing it. The titles are the README's names for the island's states.
enum IslandShowroomPose: String, CaseIterable, Sendable {
    case warmingUp
    case listening
    case speaking
    case processing
    case copyOnly
    case deliveryFailed
    case error

    var title: String {
        switch self {
        case .warmingUp: "Warming Up"
        case .listening: "Listening"
        case .speaking: "Speaking"
        case .processing: "Processing"
        case .copyOnly: "Copy-Only"
        case .deliveryFailed: "Delivery Failed"
        case .error: "Error"
        }
    }

    /// The three unclean deliveries: a one-shot gesture, then the island's 1.2 s hold.
    var isOutcome: Bool {
        switch self {
        case .copyOnly, .deliveryFailed, .error: true
        case .warmingUp, .listening, .speaking, .processing: false
        }
    }

    /// A fresh overlay model holding this pose, on the island layout a new model starts on.
    ///
    /// The one place these states are built: the overlay goldens take their models from here
    /// too, so the showroom draws exactly the body each island golden locks (two collar outcome
    /// goldens latch outcomes of their own). The levels are `MercurySpeechMeter`'s: one syllable
    /// of speech, or a quiet room. Outcomes are latched the way the controller latches them and
    /// shown at their stable endpoint.
    @MainActor
    func model() -> RecordingOverlayModel {
        let model = RecordingOverlayModel()
        switch self {
        case .warmingUp:
            // Started, not delivering audio yet. The levels are fed deliberately: `record(_:)`
            // drops every one while capture is not live, so the body cannot be driven from a
            // warm-up buffer and holds the small calm warming lens instead.
            model.update(.recording)
            Self.feed(MercurySpeechMeter.syllable, to: model)
        case .listening:
            // Every level at or below the release threshold: the voice-activity hysteresis never
            // starts, and the body holds the narrower listening pose.
            model.update(.recording)
            model.updateCaptureLive(true)
            Self.feed(MercurySpeechMeter.quietRoom, to: model)
        case .speaking:
            // The syllable carries the model past the hysteresis — two consecutive samples at or
            // above 0.10 — so the pose is speaking rather than listening.
            model.update(.recording)
            model.updateCaptureLive(true)
            Self.feed(MercurySpeechMeter.syllable, to: model)
        case .processing:
            model.update(.transcribing)
        case .copyOnly:
            Self.latch(.copiedOnly(reason: "target_terminal"), on: model)
        case .deliveryFailed:
            Self.latch(.insertFailed(reason: "paste_failed"), on: model)
        case .error:
            Self.latch(.error(.backendUnavailable), on: model)
        }
        return model
    }

    @MainActor
    private static func feed(_ levels: [Float], to model: RecordingOverlayModel) {
        for level in levels {
            model.record(level)
        }
    }

    @MainActor
    private static func latch(_ state: SessionState, on model: RecordingOverlayModel) {
        model.update(state)
        if let outcome = RecordingOverlayOutcome(state: state) {
            model.present(outcome)
        }
    }
}

extension IslandShowroomPose {
    /// What Play Again does, named per outcome so VoiceOver says which gesture replays; nil
    /// for the poses that have no gesture to replay.
    fileprivate var replayLabel: String? {
        switch self {
        case .copyOnly: "Play the copy-only gesture again"
        case .deliveryFailed: "Play the delivery-failed gesture again"
        case .error: "Play the error gesture again"
        case .warmingUp, .listening, .speaking, .processing: nil
        }
    }
}

// MARK: - Section

/// Settings ▸ Island: how the recording island looks, previewed live.
///
/// The page body under the shell's "Island" header, as cards from top to bottom: the stage
/// with the showroom and its control bar; the looks gallery with Surprise Me; four folds of
/// options — Material, Lighting, Body and Motion, independent of one another and all shut on
/// first appearance; and Position. The looks come before the folds because a look is where
/// tuning starts, and choosing one resets everything below it.
///
/// No control writes through `settingBinding`, which saves on every set: a slider drag would
/// rewrite `settings.json` at pointer rate. Each control stages the coordinator's draft
/// (`stageIsland`) — a property of its own, so a drag redraws only what reads the island; the
/// showroom draws it at once, and a dictation starting mid-drag latches exactly that — and
/// `IslandGarageEditor` commits it (`commitIsland`) once per gesture: pickers, radios,
/// switches and buttons at once; a slider when it is released; a color well, which reports
/// no editing, after 300 ms without a change; and whatever is still in flight when the
/// page goes away. Every commit is one save and one undo step that restores the whole
/// previous look, so choosing a look never costs a hand-tuned one more than ⌘Z.
///
/// Each row is an `Equatable` view of the values it shows, so a staged draft re-evaluates only
/// the rows that show what it changed and the showroom, not every bridged AppKit control:
/// re-rendering every row cost about 21 ms of main thread per pointer event with all four
/// folds open. A row reads the coordinator only when it writes, so no row body subscribes to
/// the draft.
///
/// Nothing is segmented, because a segmented control answers an accessibility press with
/// false; Coat and Room are radio groups. Pop-up menus (Metal, the preview pose) sit only where
/// no flow has to open them.
struct ConsoleIslandSection: View {
    var coordinator: DictationCoordinator

    private var a11y = A11y()
    @Environment(\.undoManager) private var undoManager

    @State private var showsMaterial = false
    @State private var showsLighting = false
    @State private var showsBody = false
    @State private var showsMotion = false

    /// Commits what the controls stage, and leaves the undo step for each commit.
    @State private var editor: IslandGarageEditor

    /// Fold rows are separated as a group's rows are: inset by the setting row's own padding.
    private static let ruleInset: CGFloat = 12

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
        _editor = State(initialValue: IslandGarageEditor(coordinator: coordinator))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Kit.Metrics.sectionGap) {
            // The stage is always present, so it carries the page's commit hooks.
            IslandShowroom(coordinator: coordinator)
                .onChange(of: coordinator.islandDraft) {
                    editor.scheduleQuietCommit(undoManager: undoManager)
                }
                .onDisappear { editor.finishEditing(undoManager: undoManager) }

            IslandLookGallery(
                look: IslandLook.matching(island),
                increasedContrast: increasedContrast,
                editor: editor,
                coordinator: coordinator
            )
            .equatable()

            fold(.material, isExpanded: $showsMaterial) { materialRows }
            fold(.lighting, isExpanded: $showsLighting) { lightingRows }
            fold(.body, isExpanded: $showsBody) { bodyRows }
            fold(.motion, isExpanded: $showsMotion) { motionRows }

            IslandPositionRow()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What every control shows: the draft in flight, else the saved look.
    private var island: IslandAppearance {
        coordinator.effectiveIsland
    }

    private var increasedContrast: Bool {
        a11y.contrast == .increased
    }

    // MARK: Folds

    /// One fold as a card: its heading opens and shuts the rows, and Restore Stock ends them.
    private func fold<Rows: View>(
        _ group: IslandGroup,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Rows
    ) -> some View {
        let rows = content()
        let restore = IslandRestoreButton(group: group, isStock: group.isStock(island), editor: editor)
        return Kit.Card {
            Kit.Disclosure(group.title, isExpanded: isExpanded, identifier: group.identifier) {
                VStack(alignment: .leading, spacing: 0) {
                    rows
                    restore.equatable()
                        .padding(.top, VoiceourMetrics.Space.sm)
                }
            }
        }
    }

    // MARK: Material

    @ViewBuilder
    private var materialRows: some View {
        IslandMetalRow(metal: island.metal, editor: editor, coordinator: coordinator)
            .equatable()
        Kit.Rule(inset: Self.ruleInset)
        IslandCoatRow(
            caption: coatCaption,
            coat: island.coat,
            film: island.film,
            candyHue: island.candyHue,
            candySaturation: island.candySaturation,
            candyBrightness: island.candyBrightness,
            reduceMotion: a11y.reduceMotion,
            editor: editor,
            coordinator: coordinator
        )
        .equatable()
        Kit.Rule(inset: Self.ruleInset)
        slider(
            "Finish",
            \.finish,
            on: IslandGrids.finish,
            id: "island.material.finish",
            caption: "Blurs the reflection from a 0% mirror to a 100% satin sheen."
        )
    }

    private var coatCaption: String {
        let sentence = Self.coatSentence(island.coat)
        // An oxide film over a near-perfect reflector barely changes what it reflects; the
        // chromium absorber is what lets Chameleon's color show on these two.
        let brightMetal = island.metal == .silver || island.metal == .aluminum
        guard brightMetal, island.coat.film != nil, island.coat != .chameleon else {
            return sentence
        }
        return sentence
            + " Silver and aluminum reflect nearly all light, so a film barely tints them."
    }

    private static func coatSentence(_ coat: IslandCoat) -> String {
        switch coat {
        case .none:
            return "Bare metal."
        case .clear:
            return "A thick clear lacquer: a slightly darker face and a whiter edge."
        case .candy:
            return "A tinted clear lacquer: the color deepens where light crosses more of it, and "
                + "the edge stays bright."
        case .pearl:
            return "A thin titanium-oxide film whose thickness sets its tint: 70 nm sky, 90 nm "
                + "pale, 115 nm gold, 130 nm rose."
        case .anodized:
            return "An oxide film whose thickness sets the color: on titanium, 25 nm bronze, 50 nm "
                + "blue, 115 nm gold, 200 nm green."
        case .oilSlick:
            return "A thick silica film: rainbow bands that slide across the body as it moves."
        case .chameleon:
            return "A chromium-and-glass interference stack whose color shifts with angle; it "
                + "shows on every metal, silver and aluminum included."
        }
    }

    // MARK: Lighting

    @ViewBuilder
    private var lightingRows: some View {
        IslandRoomRow(room: island.room, editor: editor, coordinator: coordinator)
            .equatable()
        Kit.Rule(inset: Self.ruleInset)
        slider(
            "Temperature",
            \.temperature,
            on: IslandGrids.temperature,
            id: "island.lighting.temperature",
            caption: "Sets the white balance of the room's light from 10700 K cool to 4700 K warm "
                + "without changing its brightness.",
            readout: .kelvin
        )
        Kit.Rule(inset: Self.ruleInset)
        IslandUnderglowRow(
            underglow: island.underglow,
            underglowHue: island.underglowHue,
            underglowSaturation: island.underglowSaturation,
            underglowStrength: island.underglowStrength,
            editor: editor,
            coordinator: coordinator
        )
        .equatable()
        Kit.Rule(inset: Self.ruleInset)
        slider(
            "Brightness",
            \.brightness,
            on: IslandGrids.brightness,
            id: "island.lighting.brightness",
            caption: toneCaption(
                "Moves the body's middle tone by up to half a stop either way; highlights never "
                    + "reach white."
            ),
            readout: .signed,
            disabled: increasedContrast
        )
        Kit.Rule(inset: Self.ruleInset)
        slider(
            "Contrast",
            \.contrast,
            on: IslandGrids.contrast,
            id: "island.lighting.contrast",
            caption: toneCaption(
                "Spreads or gathers the brightest highlights around that middle tone."
            ),
            readout: .signed,
            disabled: increasedContrast
        )
    }

    /// Increase Contrast's accessible anchors take precedence over Brightness and Contrast, so
    /// under it both rows say why they are disabled instead of describing an effect the island
    /// will not show. Their saved values are kept for when it is off.
    private func toneCaption(_ sentence: String) -> String {
        guard increasedContrast else { return sentence }
        return "Increase Contrast is on, so the island keeps its accessible tone; Brightness and "
            + "Contrast apply when it is off."
    }

    // MARK: Body

    @ViewBuilder
    private var bodyRows: some View {
        slider(
            "Size",
            \.size,
            on: IslandGrids.size,
            id: "island.body.size",
            caption: "Scales every pose's length and height together, down to 85%; stock is the "
                + "largest body the island holds. On the notch collar the length follows the "
                + "camera housing, so Size sets thickness only."
        )
        Kit.Rule(inset: Self.ruleInset)
        slider(
            "Build",
            \.build,
            on: IslandGrids.build,
            id: "island.body.build",
            caption: "Slims the body's height alone, down to 80%."
        )
        Kit.Rule(inset: Self.ruleInset)
        slider(
            "Crown",
            \.crown,
            on: IslandGrids.crown,
            id: "island.body.crown",
            caption: "How domed the surface is, from a nearly flat 60% to a full half-round at "
                + "100%; it moves the reflections, not the outline."
        )
        Kit.Rule(inset: Self.ruleInset)
        slider(
            "Taper",
            \.taper,
            on: IslandGrids.taper,
            id: "island.body.taper",
            caption: "Narrows the ends from the stock 46% of the middle height down to 30%."
        )
    }

    // MARK: Motion

    @ViewBuilder
    private var motionRows: some View {
        slider(
            "Tempo",
            \.tempo,
            on: IslandGrids.tempo,
            id: "island.motion.tempo",
            caption: "How fast every ripple runs; your voice still sets how tall they grow."
        )
        Kit.Rule(inset: Self.ruleInset)
        slider(
            "Viscosity",
            \.viscosity,
            on: IslandGrids.viscosity,
            id: "island.motion.viscosity",
            caption: "How quickly ripples die away, from runny at 50% to syrupy at 200%."
        )
        Kit.Rule(inset: Self.ruleInset)
        // Reduce Motion zeroes the body's autonomous motion whatever this says, so the slider
        // is disabled rather than left moving nothing. Voice and pose motion stay, and so do
        // the other rows.
        slider(
            "Shimmer",
            \.shimmer,
            on: IslandGrids.shimmer,
            id: "island.motion.shimmer",
            caption: a11y.reduceMotion
                ? "Reduce Motion is on, so the body holds still between words; Shimmer applies "
                    + "when it is off."
                : "The body's own restless motion between words.",
            disabled: a11y.reduceMotion
        )
        Kit.Rule(inset: Self.ruleInset)
        slider(
            "Reactivity",
            \.reactivity,
            on: IslandGrids.reactivity,
            id: "island.motion.reactivity",
            caption: "How strongly the body answers your voice."
        )
        Kit.Rule(inset: Self.ruleInset)
        slider(
            "Slither",
            \.slither,
            on: IslandGrids.slither,
            id: "island.motion.slither",
            caption: "How far the two edges snake apart as a crest passes and between words; below "
                + "75% they mirror into a pill."
        )
        Kit.Rule(inset: Self.ruleInset)
        slider(
            "Morph",
            \.morph,
            on: IslandGrids.morph,
            id: "island.motion.morph",
            caption: "How long the body takes to change shape between poses, from 0.19 s to "
                + "0.51 s; it still grows in and swallows itself at its usual pace.",
            readout: .seconds
        )
        Kit.Rule(inset: Self.ruleInset)
        slider(
            "Drama",
            \.drama,
            on: IslandGrids.drama,
            id: "island.motion.drama",
            caption: "How hard the body lurches after a failed delivery or collapses after an "
                + "error; a copy-only delivery only gathers."
        )
    }

    // MARK: Sliders

    /// The slider row for one field of the island in view.
    private func slider(
        _ label: String,
        _ field: WritableKeyPath<IslandAppearance, Int> & Sendable,
        on grid: IslandGrid,
        id: String,
        caption: String,
        readout: IslandReadout = .percent,
        disabled: Bool = false
    ) -> some View {
        IslandSliderRow(
            label: label,
            field: field,
            grid: grid,
            id: id,
            caption: caption,
            readout: readout,
            isDisabled: disabled,
            value: island[keyPath: field],
            editor: editor,
            coordinator: coordinator
        )
        .equatable()
    }
}

// MARK: - Rows

/// The metal the body is made of.
private struct IslandMetalRow: View, Equatable {
    let metal: IslandMetal
    let editor: IslandGarageEditor
    let coordinator: DictationCoordinator
    @Environment(\.undoManager) private var undoManager

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.metal == rhs.metal && lhs.editor === rhs.editor && lhs.coordinator === rhs.coordinator
    }

    var body: some View {
        Kit.SettingRow(
            "Metal",
            caption: "The body's color is this metal's own reflection of the room; nothing is "
                + "painted on."
        ) {
            Picker("Metal", selection: metalSelection) {
                ForEach(IslandMetal.allCases, id: \.self) { metal in
                    Text(metal.displayName).tag(metal)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("island.material.metal")
        }
    }

    private var metalSelection: Binding<IslandMetal> {
        Binding(
            get: { metal },
            set: { metal in
                guard metal != coordinator.effectiveIsland.metal else { return }
                editor.apply("Change Metal", undoManager: undoManager) { $0.metal = metal }
            }
        )
    }
}

/// The coat's own parameter — film thickness or candy color — rides the coat row and its
/// caption, because it means nothing apart from the coat that owns it.
private struct IslandCoatRow: View, Equatable {
    let caption: String
    let coat: IslandCoat
    let film: Int
    let candyHue: Int
    let candySaturation: Int
    let candyBrightness: Int
    let reduceMotion: Bool
    let editor: IslandGarageEditor
    let coordinator: DictationCoordinator
    @Environment(\.undoManager) private var undoManager

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.caption == rhs.caption && lhs.coat == rhs.coat && lhs.film == rhs.film
            && lhs.candyHue == rhs.candyHue && lhs.candySaturation == rhs.candySaturation
            && lhs.candyBrightness == rhs.candyBrightness && lhs.reduceMotion == rhs.reduceMotion
            && lhs.editor === rhs.editor && lhs.coordinator === rhs.coordinator
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Kit.SettingRow("Coat", caption: caption) {
                Picker("Coat", selection: coatSelection) {
                    ForEach(IslandCoat.allCases, id: \.self) { coat in
                        Text(coat.displayName)
                            .tag(coat)
                            .accessibilityIdentifier("island.material.coat.\(coat.rawValue)")
                    }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
                .accessibilityIdentifier("island.material.coat")
            }

            if let grid = coat.film {
                Kit.SettingRow("Film") {
                    IslandSliderControl(
                        field: \.film,
                        grid: grid,
                        id: "island.material.film",
                        accessibilityLabel: "Film thickness",
                        action: "Change Film Thickness",
                        readout: .nanometers,
                        value: film,
                        editor: editor,
                        coordinator: coordinator
                    )
                    .equatable()
                }
            }

            if coat == .candy {
                Kit.SettingRow("Color") {
                    ColorPicker("Candy color", selection: candyColor, supportsOpacity: false)
                        .labelsHidden()
                        .accessibilityValue(candyDescription)
                        .accessibilityIdentifier("island.material.candy")
                }
            }
        }
    }

    /// A coat change resets the film to that coat's stock thickness (one thickness is a
    /// different color under every coat), and the film row it inserts or removes animates
    /// unless Reduce Motion is on.
    private var coatSelection: Binding<IslandCoat> {
        Binding(
            get: { coat },
            set: { coat in
                guard coat != coordinator.effectiveIsland.coat else { return }
                withAnimation(reduceMotion ? nil : VoiceourMotion.standard) {
                    editor.apply("Change Coat", undoManager: undoManager) { $0.select(coat: coat) }
                }
            }
        )
    }

    /// The candy dye as HSB on the candy grids. A pick commits after a quiet spell, because a
    /// color well reports no editing begin or end.
    private var candyColor: Binding<Color> {
        Binding(
            get: {
                IslandColorWell.color(
                    hue: candyHue,
                    saturation: candySaturation,
                    brightness: candyBrightness
                )
            },
            set: { color in
                guard let picked = IslandColorWell.hsb(of: color) else { return }
                let hue = IslandGrids.candyHue.snap(picked.hue)
                let saturation = IslandGrids.candySaturation.snap(picked.saturation)
                let brightness = IslandGrids.candyBrightness.snap(picked.brightness)
                let current = coordinator.effectiveIsland
                guard
                    hue != current.candyHue || saturation != current.candySaturation
                        || brightness != current.candyBrightness
                else { return }
                editor.stage("Change Candy Color", undoManager: undoManager) {
                    $0.candyHue = hue
                    $0.candySaturation = saturation
                    $0.candyBrightness = brightness
                }
            }
        )
    }

    /// Spoken as a hue name with its saturation and brightness, never as an RGB triple.
    private var candyDescription: String {
        let name = candySaturation < 10 ? "Gray" : IslandColorWell.hueName(candyHue)
        return "\(name), \(candySaturation) percent saturation, "
            + "\(candyBrightness) percent brightness"
    }
}

/// The kind of room the island reflects.
private struct IslandRoomRow: View, Equatable {
    let room: MercuryWorld
    let editor: IslandGarageEditor
    let coordinator: DictationCoordinator
    @Environment(\.undoManager) private var undoManager

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.room == rhs.room && lhs.editor === rhs.editor && lhs.coordinator === rhs.coordinator
    }

    var body: some View {
        Kit.SettingRow(
            "Room",
            caption: "Studio reflects 32 soft area lights with a faint tint; Overcast reflects a "
                + "gray, cloudlike sky. Each dictation draws a new room of this kind."
        ) {
            Picker("Room", selection: roomSelection) {
                ForEach(MercuryWorld.allCases, id: \.self) { world in
                    Text(world.displayName).tag(world)
                }
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .labelsHidden()
            .accessibilityIdentifier("island.lighting.room")
        }
    }

    private var roomSelection: Binding<MercuryWorld> {
        Binding(
            get: { room },
            set: { room in
                guard room != coordinator.effectiveIsland.room else { return }
                editor.apply("Change Room", undoManager: undoManager) { $0.room = room }
            }
        )
    }
}

/// Switch and governed values share one row and are disabled together, so the row can never
/// read as a glow of some color and strength while the switch above it is off.
private struct IslandUnderglowRow: View, Equatable {
    let underglow: Bool
    let underglowHue: Int
    let underglowSaturation: Int
    let underglowStrength: Int
    let editor: IslandGarageEditor
    let coordinator: DictationCoordinator
    @Environment(\.undoManager) private var undoManager

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.underglow == rhs.underglow && lhs.underglowHue == rhs.underglowHue
            && lhs.underglowSaturation == rhs.underglowSaturation
            && lhs.underglowStrength == rhs.underglowStrength && lhs.editor === rhs.editor
            && lhs.coordinator === rhs.coordinator
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Kit.SettingRow(
                "Underglow",
                caption: "A colored light beneath the body, reflected like the rest of the room. "
                    + "Only its hue and saturation count; Strength sets how bright it glows."
            ) {
                Toggle("Underglow", isOn: underglowSwitch)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityIdentifier("island.lighting.underglow")
            }

            Kit.SettingRow("Color") {
                ColorPicker("Underglow color", selection: underglowColor, supportsOpacity: false)
                    .labelsHidden()
                    .accessibilityValue(underglowDescription)
                    .accessibilityIdentifier("island.lighting.underglow.color")
            }
            .disabled(!underglow)

            Kit.SettingRow("Strength") {
                IslandSliderControl(
                    field: \.underglowStrength,
                    grid: IslandGrids.underglowStrength,
                    id: "island.lighting.underglow.strength",
                    accessibilityLabel: "Underglow strength",
                    action: "Change Underglow Strength",
                    readout: .percent,
                    value: underglowStrength,
                    editor: editor,
                    coordinator: coordinator
                )
                .equatable()
            }
            .disabled(!underglow)
        }
    }

    private var underglowSwitch: Binding<Bool> {
        Binding(
            get: { underglow },
            set: { underglow in
                guard underglow != coordinator.effectiveIsland.underglow else { return }
                editor.apply("Change Underglow", undoManager: undoManager) { $0.underglow = underglow }
            }
        )
    }

    /// The underglow as hue and saturation alone. Strength sets how bright it glows, so its
    /// brightness is held at full and a darker pick snaps back to it.
    private var underglowColor: Binding<Color> {
        Binding(
            get: {
                IslandColorWell.color(
                    hue: underglowHue,
                    saturation: underglowSaturation,
                    brightness: 100
                )
            },
            set: { color in
                guard let picked = IslandColorWell.hsb(of: color) else { return }
                let hue = IslandGrids.underglowHue.snap(picked.hue)
                let saturation = IslandGrids.underglowSaturation.snap(picked.saturation)
                let current = coordinator.effectiveIsland
                guard hue != current.underglowHue || saturation != current.underglowSaturation
                else { return }
                editor.stage("Change Underglow Color", undoManager: undoManager) {
                    $0.underglowHue = hue
                    $0.underglowSaturation = saturation
                }
            }
        )
    }

    /// Spoken as a hue name with its saturation; below 10 % saturation the light is white.
    private var underglowDescription: String {
        let name = underglowSaturation < 10 ? "White" : IslandColorWell.hueName(underglowHue)
        return "\(name), \(underglowSaturation) percent saturation"
    }
}

/// A slider and the sentence that explains it.
private struct IslandSliderRow: View, Equatable {
    let label: String
    let field: WritableKeyPath<IslandAppearance, Int> & Sendable
    let grid: IslandGrid
    let id: String
    let caption: String
    let readout: IslandReadout
    let isDisabled: Bool
    let value: Int
    let editor: IslandGarageEditor
    let coordinator: DictationCoordinator

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.label == rhs.label && lhs.field == rhs.field && lhs.grid == rhs.grid && lhs.id == rhs.id
            && lhs.caption == rhs.caption && lhs.readout == rhs.readout
            && lhs.isDisabled == rhs.isDisabled && lhs.value == rhs.value && lhs.editor === rhs.editor
            && lhs.coordinator === rhs.coordinator
    }

    var body: some View {
        Kit.SettingRow(label, caption: caption) {
            IslandSliderControl(
                field: field,
                grid: grid,
                id: id,
                accessibilityLabel: label,
                action: "Change \(label)",
                readout: readout,
                value: value,
                editor: editor,
                coordinator: coordinator
            )
            .equatable()
        }
        .disabled(isDisabled)
    }
}

/// One integer option as a slider and its readout, in the shape every island slider shares;
/// the setting row around it carries the visible title.
///
/// The value is an integer in UI units moved by the grid's explicit step, so the published
/// accessibility value is an integer (a fractional step leaks float error into it) and a
/// look compares by exact equality. A slider without a label view publishes no label, so
/// it hides its label and names itself, and speaks the readout as its value description.
/// The readout beside it therefore stays out of accessibility. No end labels:
/// `minimumValueLabel`/`maximumValueLabel` publish 19×13 pt step buttons.
private struct IslandSliderControl: View, Equatable {
    let field: WritableKeyPath<IslandAppearance, Int> & Sendable
    let grid: IslandGrid
    let id: String
    let accessibilityLabel: String
    let action: String
    let readout: IslandReadout
    let value: Int
    let editor: IslandGarageEditor
    let coordinator: DictationCoordinator
    @Environment(\.undoManager) private var undoManager

    /// Wide enough that one grid step is several points of travel on the longest grid; a
    /// narrow page shrinks it as far as the minimum rather than overflowing the card.
    private static let sliderWidth: CGFloat = 220
    private static let sliderMinimumWidth: CGFloat = 120

    init(
        field: WritableKeyPath<IslandAppearance, Int> & Sendable,
        grid: IslandGrid,
        id: String,
        accessibilityLabel: String,
        action: String,
        readout: IslandReadout,
        value: Int,
        editor: IslandGarageEditor,
        coordinator: DictationCoordinator
    ) {
        self.field = field
        self.grid = grid
        self.id = id
        self.accessibilityLabel = accessibilityLabel
        self.action = action
        self.readout = readout
        self.value = value
        self.editor = editor
        self.coordinator = coordinator
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.field == rhs.field && lhs.grid == rhs.grid && lhs.id == rhs.id
            && lhs.accessibilityLabel == rhs.accessibilityLabel && lhs.action == rhs.action
            && lhs.readout == rhs.readout && lhs.value == rhs.value && lhs.editor === rhs.editor
            && lhs.coordinator === rhs.coordinator
    }

    var body: some View {
        HStack(spacing: VoiceourMetrics.Space.sm) {
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { proposed in
                        let snapped = grid.snap(Int(proposed.rounded()))
                        guard snapped != coordinator.effectiveIsland[keyPath: field] else { return }
                        editor.stage(action, undoManager: undoManager) { $0[keyPath: field] = snapped }
                    }
                ),
                in: Double(grid.range.lowerBound)...Double(grid.range.upperBound),
                step: Double(grid.step),
                onEditingChanged: { editing in
                    editor.sliderEditingChanged(editing, undoManager: undoManager)
                }
            )
            .labelsHidden()
            .frame(minWidth: Self.sliderMinimumWidth, idealWidth: Self.sliderWidth, maxWidth: Self.sliderWidth)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(readout.spoken(value))
            .accessibilityIdentifier(id)

            Text(readout.text(value))
                .roleStyle(.meta)
                .monospacedDigit()
                .frame(width: VoiceourMetrics.Field.readout, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}

/// Resets one fold alone; the Stock look is the reset for every fold at once.
private struct IslandRestoreButton: View, Equatable {
    let group: IslandGroup
    let isStock: Bool
    let editor: IslandGarageEditor
    @Environment(\.undoManager) private var undoManager

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.group == rhs.group && lhs.isStock == rhs.isStock && lhs.editor === rhs.editor
    }

    var body: some View {
        Kit.Button("Restore Stock", systemImage: "arrow.uturn.backward") {
            editor.apply(group.restoreAction, undoManager: undoManager) { group.restore(&$0) }
        }
        .disabled(isStock)
        // The closure form replaces the label the kit button derives from its title,
        // whatever order the modifiers resolve in.
        .accessibilityLabel { _ in Text(group.restoreLabel) }
        .accessibilityIdentifier(group.restoreIdentifier)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: - Showroom

/// The stage: the production island renderer in a generated room of its own, on the island's
/// layout, which every display can show (a collar exists only around the camera housing it
/// frames), magnified twice over in a lit studio, in a card with its control bar below.
///
/// Never the real panel: a visible island means a live microphone, and the island reports
/// state through its shape alone, so a speaking body there would misstate whether the
/// microphone is on. The surface is the production `MercurySurface` with a hit region of its
/// own, hidden from accessibility, rasterized at twice the production scale so the magnified
/// body stays sharp. The studio behind it is drawn from the look's own light on the studio's
/// constant dark ground, never the console theme, and the floor under it — contact shadow and
/// reflection — is derived from each image the surface presents, through a link that never
/// invalidates SwiftUI. On a page narrower than the full-size stage the whole stage scales
/// down, keeping its aspect. One static-text element over the stage states the pose and the
/// room, and the look pill in the bar below states the look.
///
/// The speaking body needs no clock: the engine turns the voice phase every substep, so the
/// fixed sample buffer makes a crest train that keeps travelling with nothing published
/// through SwiftUI. The engine survives pose changes, so choosing an outcome plays its gesture
/// from the current body and then holds it.
private struct IslandShowroom: View {
    var coordinator: DictationCoordinator
    private var a11y = A11y()

    @State private var pose: IslandShowroomPose
    /// Which room of the showroom's sequence is up; view state, never saved.
    @State private var room = 1
    /// Whether at least a fifth of the stage is scrolled into view; out of it the surface is
    /// suspended. Starts false: the scroll visibility callback reports a stage that appears in
    /// view, and one that never comes into view draws nothing.
    @State private var onScreen = false
    /// Whether the console window shows any of itself: false while it is miniaturized, on
    /// another Space, hidden with the app or fully covered by other windows, where a live stage
    /// would keep its display link drawing frames nobody sees. Starts true, so a stage that
    /// appears in view draws before the first report.
    @State private var windowVisible = true

    /// The look the renderer draws: the effective look with bake-class changes throttled.
    @State private var shownIsland: IslandAppearance
    @State private var lastBake: ContinuousClock.Instant?
    @State private var pendingBake: Task<Void, Never>?

    @State private var replayGeneration = 0
    @State private var isReplaying = false
    @State private var replayHold: Task<Void, Never>?

    /// Carries each presented body image to the floor view below it, outside SwiftUI.
    @State private var floorLink: ShowroomFloorLink

    /// The substep the overlay goldens pin, so a still preview is the body they lock.
    private static let stillStep = 600
    private static let bakeInterval: Duration = .milliseconds(100)
    /// Nothing reads the showroom's silhouette — no panel routes the mouse against it — but
    /// the engine publishes one, so it gets a region of its own rather than the panel's.
    private static let hitRegion = MercuryHitRegion()

    /// Every pose's drives, built once: the models are fixed, so the updates a slider drag
    /// causes rebuild none of them.
    private static let posedDrives = Dictionary(
        uniqueKeysWithValues: IslandShowroomPose.allCases.map { ($0, PosedDrives($0)) }
    )

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
        _pose = State(initialValue: RenderOverrides.islandShowroomPose ?? .speaking)
        _shownIsland = State(initialValue: coordinator.effectiveIsland)
        _floorLink = State(initialValue: ShowroomFloorLink())
    }

    var body: some View {
        let look = MercuryLook(island: shownIsland)
        Kit.Card {
            VStack(alignment: .leading, spacing: VoiceourMetrics.Space.md) {
                stage(look: look)

                controls
                    .frame(maxWidth: .infinity)

                IslandCaption(caption)

                if coordinator.state.isActive {
                    IslandCaption("Applies from the next recording.")
                }
            }
        }
        .onChange(of: coordinator.effectiveIsland) { _, island in
            show(island)
        }
        .onChange(of: committedMotion) {
            replayAfterMotionCommit()
        }
        .onAppear {
            shownIsland = coordinator.effectiveIsland
        }
        .onDisappear {
            pendingBake?.cancel()
            pendingBake = nil
            replayHold?.cancel()
            replayHold = nil
            isReplaying = false
        }
    }

    /// The studio, the body standing on its horizon, and the floor it casts, behind the floor
    /// image's top half so the reflection runs down from the body's base. Below the full-size
    /// width every measure scales by the same factor; the surfaces keep their raster scale and
    /// their layers fit each image to the smaller frame.
    private func stage(look: MercuryLook) -> some View {
        let increasedContrast = a11y.contrast == .increased
        let fullSizeWidth = IslandStageMetrics.fullSizeWidth
        let stageFrame = IslandStageFrame(fullSizeWidth: fullSizeWidth, fullHeight: IslandStageMetrics.height)
        return stageFrame {
            GeometryReader { proxy in
                let scale = IslandStageFrame.scale(width: proxy.size.width, fullSizeWidth: fullSizeWidth)
                let bodySize = IslandStageMetrics.bodySize
                let floor = IslandStageMetrics.floorSize
                ZStack(alignment: .top) {
                    IslandStageBackdrop(
                        lighting: ShowroomStage.Lighting(look: look),
                        horizon: IslandStageMetrics.horizon * scale,
                        scale: scale,
                        increasedContrast: increasedContrast
                    )
                    .equatable()

                    ZStack(alignment: .top) {
                        ShowroomFloor(link: floorLink)
                            .frame(width: floor.width * scale, height: floor.height * scale)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)

                        MercurySurface(configuration: configuration(look: look), hitRegion: Self.hitRegion)
                            .frame(width: bodySize.width * scale, height: bodySize.height * scale)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .frame(width: floor.width * scale, height: floor.height * scale, alignment: .top)
                    .transaction { $0.animation = nil }
                    .padding(.top, IslandStageMetrics.bodyTop * scale)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
        }
        .clipShape(
            RoundedRectangle(cornerRadius: IslandStageMetrics.cornerRadius, style: .continuous)
        )
        .overlay {
            Color.clear
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("island.showroom")
                .accessibilityLabel("Island preview")
                .accessibilityValue(previewValue)
                .accessibilityAddTraits(.isStaticText)
        }
        .onScrollVisibilityChange(threshold: 0.2) { visible in
            onScreen = visible
        }
        .background {
            WindowVisibilityReader { visible in
                windowVisible = visible
            }
            .accessibilityHidden(true)
        }
    }

    private var controls: some View {
        IslandShowroomControls(
            lookMark: lookMark,
            pose: pose,
            replayLabel: pose.replayLabel,
            isReplaying: isReplaying,
            setPose: { pose = $0 },
            anotherRoom: { room += 1 },
            replay: { replay() }
        )
        .equatable()
    }

    private var caption: String {
        let sentence =
            "Previews the island in a generated room of its own. Each dictation draws a "
            + "new room and uses these settings from its start."
        guard a11y.reduceMotion else { return sentence }
        return sentence + " Reduce Motion is on, so the preview holds still."
    }

    private var lookMark: String {
        IslandLook.matching(coordinator.effectiveIsland)?.displayName ?? "Custom"
    }

    /// The pose and the room by name, e.g. "Speaking, Studio room 1". The room kind is the
    /// effective one, so it is right the moment a radio moves, before any throttled rebake.
    private var previewValue: String {
        "\(pose.title), \(coordinator.effectiveIsland.room.displayName) room \(room)"
    }

    /// The production configuration at twice the production raster scale, so the magnified
    /// body is drawn at its own resolution rather than scaled up, and with every presented
    /// image handed to the floor.
    private func configuration(look: MercuryLook) -> MercurySurfaceView.Configuration {
        var configuration = MercurySurfaceView.Configuration(
            seed: roomSeed,
            look: look,
            drive: Self.posed(pose).drive(reduceMotion: a11y.reduceMotion),
            appearance: MercuryAppearance(increasedContrast: a11y.contrast == .increased),
            layout: .island,
            pinnedStep: pinnedStep,
            isSuspended: isSuspended,
            replayGeneration: replayGeneration,
            replaySource: Self.posed(.processing).target,
            // No controller conducts the showroom and no panel carries it.
            onFrame: nil,
            panelMotion: nil
        )
        configuration.rasterScale = IslandStageMetrics.magnification * MercuryMetrics.rasterScale
        configuration.onPresent = floorLink.present
        return configuration
    }

    /// Room 1 is the overlay goldens' room (`defaultSeed`, or the seam's seed in the harness);
    /// room n > 1 is the first SplitMix64 output for the state `base + (n − 1)`. Deterministic
    /// in production too, so it needs no seam of its own: dictations keep drawing random rooms,
    /// and Another Room only advances `n`.
    private var roomSeed: UInt64 {
        let base = RenderOverrides.mercurySeed ?? MercuryMetrics.defaultSeed
        return room == 1 ? base : Self.splitMix64(base &+ UInt64(room - 1))
    }

    /// The harness's seam step; otherwise live at display cadence, or under Reduce Motion one
    /// still frame from the pinned-frame path with no display link. A replay runs live for its
    /// one hold even then, because the island keeps its gestures under Reduce Motion;
    /// returning to still is a cached frame, not a rebake.
    private var pinnedStep: Int? {
        if let step = RenderOverrides.mercuryStep {
            return step
        }
        if isReplaying {
            return nil
        }
        return a11y.reduceMotion ? Self.stillStep : nil
    }

    /// Out of view, scrolled away or in a window that shows none of itself, the stage draws
    /// nothing, live or still, so a change made in the folds below costs no frame, and the
    /// stage's return draws the current look at once. A replay keeps it drawing through its one
    /// hold: Play Again sits below the stage and can be pressed with less than a fifth of the
    /// stage in view, and its gesture plays then, not whenever the stage next returns. The
    /// harness pins a seam step and is never suspended, so a scene draws that frame whatever its
    /// scroll position or window.
    private var isSuspended: Bool {
        RenderOverrides.mercuryStep == nil && !(onScreen && windowVisible) && !isReplaying
    }

    /// The committed Morph and Drama: only a commit replays, not every step of a drag.
    private var committedMotion: [Int] {
        [coordinator.settings.island.morph, coordinator.settings.island.drama]
    }

    /// Bake-class changes — metal, coat, film, candy dye, finish, room, temperature and
    /// underglow — rebuild a paint table or relight the room, the costliest work a look change
    /// can cause when the engine's caches lack it, so they reach the renderer at most once per
    /// 100 ms: the first at once, the last when changes stop. That bounds a drag's main-thread
    /// cost to about a tenth. Every other change goes through on the update that carries it.
    private func show(_ island: IslandAppearance) {
        let unbaked = island.withBakeInputs(of: shownIsland)
        guard unbaked != island else {
            shownIsland = island
            return
        }
        let now = ContinuousClock.now
        let bakeDue = lastBake.map { now - $0 >= Self.bakeInterval } ?? true
        if pendingBake == nil, bakeDue {
            shownIsland = island
            lastBake = now
            return
        }
        shownIsland = unbaked
        guard pendingBake == nil else { return }
        let deadline = (lastBake ?? now) + Self.bakeInterval
        pendingBake = Task { @MainActor in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            pendingBake = nil
            lastBake = .now
            shownIsland = coordinator.effectiveIsland
        }
    }

    /// Replays the outcome from the processing body, as the island plays it after a real
    /// dictation, and holds Play Again disabled for the island's 1.2 s dwell so presses cannot
    /// stack the gesture's velocity.
    private func replay() {
        replayGeneration += 1
        isReplaying = true
        replayHold?.cancel()
        replayHold = Task { @MainActor in
            try? await Task.sleep(for: .seconds(RecordingOverlayMetrics.outcomeDwell))
            guard !Task.isCancelled else { return }
            isReplaying = false
            replayHold = nil
        }
    }

    /// Morph and Drama only show in a transition, so committing either while an outcome is in
    /// view plays it again. Under Reduce Motion only Play Again replays: the preview holds
    /// still unless asked.
    private func replayAfterMotionCommit() {
        guard pose.isOutcome, onScreen, !a11y.reduceMotion, !isReplaying else { return }
        replay()
    }

    private static func posed(_ pose: IslandShowroomPose) -> PosedDrives {
        posedDrives[pose] ?? PosedDrives(pose)
    }

    /// The first output of SplitMix64 seeded with `state`.
    private static func splitMix64(_ state: UInt64) -> UInt64 {
        var z = state &+ 0x9e37_79b9_7f4a_7c15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

/// Reports whether the window hosting it shows any of itself, from AppKit's occlusion state:
/// false while that window is miniaturized, on another Space, hidden with its app or fully
/// covered. The first report waits a main-actor turn, because a view moves into its window
/// inside SwiftUI's update pass, which must not publish state.
private struct WindowVisibilityReader: NSViewRepresentable {
    let report: (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView {
        ReaderView(report: report)
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.report = report
    }

    final class ReaderView: NSView {
        var report: (Bool) -> Void
        private var occlusionObserver: NSObjectProtocol?

        init(report: @escaping (Bool) -> Void) {
            self.report = report
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            occlusionObserver.map(NotificationCenter.default.removeObserver)
            occlusionObserver = nil
            guard let window else { return }
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reportVisibility()
                }
            }
            Task { @MainActor [weak self] in
                self?.reportVisibility()
            }
        }

        private func reportVisibility() {
            guard let window else { return }
            report(window.occlusionState.contains(.visible))
        }
    }
}

/// The stage's control bar. The look pill is the one place the current look is named, and the
/// only Custom cue: it sits under the preview, so it stays beside the body while it is tuned.
/// When the titled bar is wider than the card, its buttons draw their glyphs alone and keep
/// their titles as accessibility labels, so a narrow page keeps every control on one line.
private struct IslandShowroomControls: View, Equatable {
    let lookMark: String
    let pose: IslandShowroomPose
    let replayLabel: String?
    let isReplaying: Bool
    let setPose: @MainActor @Sendable (IslandShowroomPose) -> Void
    let anotherRoom: @MainActor @Sendable () -> Void
    let replay: @MainActor @Sendable () -> Void

    /// Leaves the closures out: they only write the showroom's `@State`, whose storage a
    /// captured copy of the showroom reaches just as the current one does.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.lookMark == rhs.lookMark && lhs.pose == rhs.pose && lhs.replayLabel == rhs.replayLabel
            && lhs.isReplaying == rhs.isReplaying
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar.environment(\.kitCompactControls, false)
            bar.environment(\.kitCompactControls, true)
        }
    }

    private var bar: some View {
        HStack(spacing: VoiceourMetrics.Space.sm) {
            Kit.Pill(lookMark, tone: .neutral, size: .regular)
                .accessibilityIdentifier("island.showroom.look")

            Picker("Preview pose", selection: Binding(get: { pose }, set: setPose)) {
                ForEach(IslandShowroomPose.allCases, id: \.self) { pose in
                    Text(pose.title).tag(pose)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("island.showroom.pose")

            Kit.Button("Another Room", systemImage: "shuffle") { anotherRoom() }
                .help(
                    "Shows the preview in a different generated room; every dictation draws "
                        + "its own."
                )
                .accessibilityIdentifier("island.showroom.room")

            if let replayLabel {
                Kit.Button("Play Again", systemImage: "arrow.counterclockwise") { replay() }
                    .disabled(isReplaying)
                    // The closure form replaces the label the kit button derives from its
                    // title, whatever order the modifiers resolve in.
                    .accessibilityLabel { _ in Text(replayLabel) }
                    .accessibilityIdentifier("island.showroom.replay")
            }
        }
    }
}

/// A showroom pose's drives, built from its fixed overlay model by the builder the island's own
/// ribbon uses, `MercurySimulation.Drive.target(for:reduceMotion:)`, so the showroom asks the
/// body for what a dictation in that pose asks of the island. Reduce Motion is one of the
/// drive's inputs, so each pose keeps a drive for either setting.
private struct PosedDrives {
    /// The pose the model asks for, which a replay starts the body from.
    let target: MercuryPose
    private let standard: MercurySimulation.Drive
    private let reducedMotion: MercurySimulation.Drive

    @MainActor
    init(_ pose: IslandShowroomPose) {
        let model = pose.model()
        standard = .target(for: model, reduceMotion: false)
        reducedMotion = .target(for: model, reduceMotion: true)
        target = standard.pose
    }

    func drive(reduceMotion: Bool) -> MercurySimulation.Drive {
        reduceMotion ? reducedMotion : standard
    }
}

// MARK: - Position

/// Dock Island: the island is docked unless the reader tore it off and let it go somewhere, and
/// the button sends it home. It persists docked and asks the overlay controller to follow
/// (`RecordingOverlayPlacement.requestDock()`): a visible island docks as its own Dock island
/// action docks it, and a hidden one starts its next session docked.
///
/// Live while the reader tears the island off or docks it during a dictation: every defaults
/// write re-reads the persisted placement. A view of its own, so the updates a slider drag causes
/// in the section never resubscribe that observer.
private struct IslandPositionRow: View {
    @State private var isFree = false

    var body: some View {
        Kit.Group {
            Kit.SettingRow("Position", caption: caption) {
                Kit.Button("Dock Island", systemImage: "dock.arrow.down.rectangle") {
                    RecordingOverlayPlacement.requestDock()
                    refresh()
                }
                .disabled(!isFree)
                // The closure form replaces the label the kit button derives from its title,
                // whatever order the modifiers resolve in.
                .accessibilityLabel { _ in Text("Dock the island") }
                .accessibilityIdentifier("island.position.dock")
            }
        }
        .onAppear { refresh() }
        // Defaults can change on any thread; the read and the state write stay on main.
        .onReceive(
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .receive(on: RunLoop.main)
        ) { _ in
            refresh()
        }
    }

    private var caption: String {
        isFree
            ? "Kept where you let it go, at the same relative spot on each display."
            : "On a display with a camera notch the island frames the notch; elsewhere it floats "
                + "centered near the top. Drag it \(Int(RecordingOverlayDrag.tearOffDistance)) pt "
                + "to tear it off."
    }

    private func refresh() {
        let free = RecordingOverlayPlacement.persisted.isFree
        if free != isFree {
            isFree = free
        }
    }
}

// MARK: - Shared pieces

/// The Island page's explanatory voice outside a setting row: one sentence in the `meta`
/// role, never truncated mid-clause.
struct IslandCaption: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .roleStyle(.meta)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One fold of options and what its Restore Stock resets. `island.group.<raw>` identifies the
/// fold's label and `island.<raw>.stock` its button.
private enum IslandGroup: String {
    case material
    case lighting
    case body
    case motion

    var title: String {
        switch self {
        case .material: "Material"
        case .lighting: "Lighting"
        case .body: "Body"
        case .motion: "Motion"
        }
    }

    var identifier: String { "island.group.\(rawValue)" }
    var restoreIdentifier: String { "island.\(rawValue).stock" }
    var restoreLabel: String { "Restore stock \(rawValue)" }
    var restoreAction: String { "Restore Stock \(title)" }

    func isStock(_ island: IslandAppearance) -> Bool {
        switch self {
        case .material: island.hasStockMaterial
        case .lighting: island.hasStockLighting
        case .body: island.hasStockBody
        case .motion: island.hasStockMotion
        }
    }

    func restore(_ island: inout IslandAppearance) {
        switch self {
        case .material: island.restoreStockMaterial()
        case .lighting: island.restoreStockLighting()
        case .body: island.restoreStockBody()
        case .motion: island.restoreStockMotion()
        }
    }
}

/// How a slider states its value: the readout beside it and what VoiceOver speaks. Integers
/// print without grouping separators, so no locale reaches a golden.
private enum IslandReadout {
    /// "60%", spoken "60 percent".
    case percent
    /// Film thickness: "70 nm", spoken "70 nanometers".
    case nanometers
    /// The Planckian temperature the room's white balance sets, to the nearest 100 K: "6500 K",
    /// spoken "6500 kelvin". All 21 positions read differently.
    case kelvin
    /// Either side of stock: "+20", "0", "−30" (a true minus sign), spoken "plus 20", "0",
    /// "minus 30".
    case signed
    /// Morph as the relaxation time it gives the body's aspect and sway gels, τ = 0.32 s × v/100:
    /// "0.32 s", spoken "0.32 seconds". All 11 positions read differently at two decimals.
    case seconds

    func text(_ value: Int) -> String {
        switch self {
        case .percent: "\(value)%"
        case .nanometers: "\(value) nm"
        case .kelvin: "\(Self.kelvin(value)) K"
        case .signed: value > 0 ? "+\(value)" : value < 0 ? "\u{2212}\(-value)" : "0"
        case .seconds: String(format: "%.2f s", Self.seconds(value))
        }
    }

    func spoken(_ value: Int) -> String {
        switch self {
        case .percent: "\(value) percent"
        case .nanometers: "\(value) nanometers"
        case .kelvin: "\(Self.kelvin(value)) kelvin"
        case .signed: value > 0 ? "plus \(value)" : value < 0 ? "minus \(-value)" : "0"
        case .seconds: String(format: "%.2f seconds", Self.seconds(value))
        }
    }

    private static func kelvin(_ value: Int) -> Int {
        Int((MercuryWhiteBalance.kelvin(temperature: Double(value) / 100) / 100).rounded()) * 100
    }

    private static func seconds(_ value: Int) -> Double {
        Double(value) / 100 / MercuryBodyShape.aspectGel.relaxationRate
    }
}

/// The arithmetic both color wells share: HSB on the sRGB primaries, and the hue names their
/// spoken values use.
private enum IslandColorWell {
    /// Twelve 30° bands centred on red at 0°: the names a color well's spoken value uses.
    private static let hueNames = [
        "Red", "Orange", "Yellow", "Lime", "Green", "Mint",
        "Cyan", "Azure", "Blue", "Violet", "Magenta", "Pink",
    ]

    static func hueName(_ hue: Int) -> String {
        hueNames[((hue % 360) + 360 + 15) % 360 / 30]
    }

    /// HSB on the sRGB primaries, the space the renderer's `MercuryColor` decodes too.
    static func color(hue: Int, saturation: Int, brightness: Int) -> Color {
        Color(
            hue: Double(hue) / 360,
            saturation: Double(saturation) / 100,
            brightness: Double(brightness) / 100
        )
    }

    /// A picked color in whole degrees and percent on the sRGB primaries, or nil for a color
    /// with no RGB form.
    static func hsb(of color: Color) -> (hue: Int, saturation: Int, brightness: Int)? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return (
            hue: Int((hue * 360).rounded()) % 360,
            saturation: Int((saturation * 100).rounded()),
            brightness: Int((brightness * 100).rounded())
        )
    }
}

extension IslandAppearance {
    /// This appearance with `source`'s bake inputs: every field whose change rebuilds the
    /// paint table or the room.
    fileprivate func withBakeInputs(of source: IslandAppearance) -> IslandAppearance {
        var result = self
        result.metal = source.metal
        result.coat = source.coat
        result.film = source.film
        result.candyHue = source.candyHue
        result.candySaturation = source.candySaturation
        result.candyBrightness = source.candyBrightness
        result.finish = source.finish
        result.room = source.room
        result.temperature = source.temperature
        result.underglow = source.underglow
        result.underglowHue = source.underglowHue
        result.underglowSaturation = source.underglowSaturation
        result.underglowStrength = source.underglowStrength
        return result
    }
}
