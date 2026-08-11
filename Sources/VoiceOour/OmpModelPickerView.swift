import SwiftUI
import VoiceMac

/// The Model row for the Oh My Pi provider.
///
/// The field this replaced was free text, and a free-text model id is a trap:
/// OMP already knows exactly which models this Mac can reach, and every id the
/// user could type instead is either that same list or a typo that only shows
/// up as a failed CHECK. So the options are inherited from `omp models --json`
/// and the user picks one.
///
/// The catalog is large — several hundred models across every provider OMP can
/// broker — which drives two decisions. Models whose provider has a live OMP
/// account are grouped first, because those are the ones that will actually
/// answer. And the list renders a bounded number of rows rather than scrolling
/// inside an already-scrolling pane: past that, the filter is the interaction,
/// and a caption says how much is being withheld so the cap is never silent.
struct OmpModelPickerRow: View {
    let models: [OmpAvailableModel]
    let catalogState: OmpModelCatalogState
    let connectedProviderIDs: Set<String>
    /// The selector the refiner would use right now, default included.
    let resolvedModel: String
    /// Whether that selector came from the provider default rather than a choice.
    let isDefaulted: Bool
    let defaultModel: String
    @Binding var filter: String
    let onRefresh: () -> Void
    let onSelect: (String) -> Void

    /// Enough rows to browse a connected provider's shortlist without turning
    /// the pane into a scroller. Measured against the real catalog: the three
    /// subscription providers vend 7, 8 and 26 models, so a filter of one word
    /// lands inside this cap for every realistic search.
    private static let visibleRowLimit = 8

    @Environment(\.isEnabled) private var isEnabled
    private var a11y = A11y()

    init(
        models: [OmpAvailableModel],
        catalogState: OmpModelCatalogState,
        connectedProviderIDs: Set<String>,
        resolvedModel: String,
        isDefaulted: Bool,
        defaultModel: String,
        filter: Binding<String>,
        onRefresh: @escaping () -> Void,
        onSelect: @escaping (String) -> Void
    ) {
        self.models = models
        self.catalogState = catalogState
        self.connectedProviderIDs = connectedProviderIDs
        self.resolvedModel = resolvedModel
        self.isDefaulted = isDefaulted
        self.defaultModel = defaultModel
        self._filter = filter
        self.onRefresh = onRefresh
        self.onSelect = onSelect
    }

    var body: some View {
        let matches = filteredModels
        // The row the user already chose comes first, ahead of its own group's
        // ordering. Without this the eight-row cap can hide the current
        // selection behind an alphabetically earlier provider, and the picker
        // then shows a list with nothing marked in use. Written as an explicit
        // partition rather than a comparator because `sorted(by:)` makes no
        // stability promise, and everything below the pinned row must keep the
        // catalog's order.
        let ranked =
            currentSelection(in: matches).map { current in
                [current] + matches.filter { $0.selector != current.selector }
            } ?? matches
        let connected = ranked.filter { connectedProviderIDs.contains($0.provider) }
        let others = ranked.filter { !connectedProviderIDs.contains($0.provider) }
        let shown = Array((connected + others).prefix(Self.visibleRowLimit))
        let shownIDs = Set(shown.map(\.selector))

        HStack(alignment: .top, spacing: VoiceOourMetrics.Space.xl) {
            Text("Model")
                .font(VoiceOourTypography.label)
                .foregroundStyle(isEnabled ? VoiceOourPalette.Text.high : a11y.textLow)
                .recordTextRole(
                    .label,
                    foreground: isEnabled ? VoiceOourPalette.Text.high : a11y.textLow
                )
                .frame(width: VoiceOourMetrics.Column.settingsLabel, alignment: .leading)

            VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.xs) {
                HStack(spacing: VoiceOourMetrics.Space.sm) {
                    TextField("Filter models", text: $filter)
                        .textFieldStyle(GlassTextFieldStyle(font: VoiceOourTypography.bodyMono))
                        .accessibilityLabel("Filter models")
                        .accessibilityIdentifier("refinement.model.filter")

                    StatusChip(label: catalogStatus.label, mode: catalogStatus.mode, size: .compact)

                    Button(catalogState.isLoading ? "REFRESHING…" : "REFRESH", action: onRefresh)
                        .buttonStyle(
                            GlassButtonStyle(kind: .ghost, isInFlight: catalogState.isLoading)
                        )
                        .disabled(catalogState.isLoading)
                        .accessibilityLabel("Refresh Oh My Pi models")
                        .accessibilityIdentifier("refinement.model.refresh")
                }
                .frame(minHeight: VoiceOourMetrics.Control.medium)

                VStack(alignment: .leading, spacing: 0) {
                    if isDefaulted { defaultOptionRow }
                    if !shown.isEmpty {
                        let connectedShown = connected.filter { shownIDs.contains($0.selector) }
                        let otherShown = others.filter { shownIDs.contains($0.selector) }
                        if !connectedShown.isEmpty {
                            modelGroup(
                                "CONNECTED PROVIDERS",
                                models: connectedShown,
                                isFirst: !isDefaulted
                            )
                        }
                        if !otherShown.isEmpty {
                            modelGroup(
                                "OTHER PROVIDERS",
                                models: otherShown,
                                isFirst: !isDefaulted && connectedShown.isEmpty
                            )
                        }
                    }
                }
                .plateSurface(kind: .well, cornerRadius: VoiceOourMetrics.Radius.row)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Oh My Pi models")

                if case .failed(let detail) = catalogState {
                    CaptionText(detail, color: VoiceOourPalette.Signal.crimson)
                }
                CaptionText(listSummary(shown: shown.count, matched: matches.count))
                CaptionText(
                    "Models come from your installed OMP, so this list is exactly what it can reach. "
                        + "CHECK confirms the selection is still available."
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, VoiceOourMetrics.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .anchorPreference(key: SettingsRowBoundsPreferenceKey.self, value: .bounds) { [$0] }
        .settingsContentLead(VoiceOourMetrics.Space.sm)
    }

    // MARK: - Rows

    /// Present only until the user picks. It is the row that says what happens
    /// if they never do, and once a model is chosen the list is nothing but
    /// real models — "defaulted" and "chosen" are then mutually exclusive
    /// states of the list rather than a distinction a reader has to infer. The
    /// default model itself is in the catalog like any other, so picking it
    /// explicitly is always available.
    private var defaultOptionRow: some View {
        OmpModelOptionRow(
            title: "Provider default",
            detail: defaultModel,
            identifier: "refinement.model.option.default",
            accessibilityLabel: "Provider default (\(defaultModel))",
            isSelected: true,
            action: { onSelect("") }
        )
    }

    @ViewBuilder
    private func modelGroup(
        _ title: String,
        models: [OmpAvailableModel],
        isFirst: Bool
    ) -> some View {
        if !isFirst { HairlineDivider() }
        Text(title)
            .font(VoiceOourTypography.micro)
            .tracking(TextRole.micro.tracking)
            .foregroundStyle(a11y.textLow)
            .recordTextRole(.micro, foreground: a11y.textLow)
            .padding(.horizontal, VoiceOourMetrics.Space.sm)
            .padding(.top, VoiceOourMetrics.Space.sm)
            .padding(.bottom, VoiceOourMetrics.Space.xs)

        ForEach(models, id: \.selector) { model in
            if model.selector != models.first?.selector { HairlineDivider() }
            OmpModelOptionRow(
                title: model.name,
                detail: model.selector,
                identifier: "refinement.model.option.\(model.selector)",
                accessibilityLabel: "\(model.name) (\(model.selector))",
                isSelected: isCurrent(model),
                action: { onSelect(model.selector) }
            )
        }
    }

    // MARK: - Derived state

    /// Matches on both halves of the selector and on the display name, because
    /// a user searching "haiku" and a user searching "anthropic" are both
    /// naming the same model by the part of it they remember.
    private var filteredModels: [OmpAvailableModel] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return models }
        return models.filter {
            $0.selector.localizedCaseInsensitiveContains(needle)
                || $0.name.localizedCaseInsensitiveContains(needle)
        }
    }

    /// Whether this row is the model the refiner would use. False while the
    /// selection is the provider default, because the default row owns that
    /// mark and exactly one row in the list may wear it.
    private func isCurrent(_ model: OmpAvailableModel) -> Bool {
        !isDefaulted && model.selector == resolvedModel
    }

    private func currentSelection(in candidates: [OmpAvailableModel]) -> OmpAvailableModel? {
        candidates.first(where: isCurrent)
    }

    /// A selector OMP no longer lists still refines — it is sent verbatim and
    /// fails at request time. Saying so here is the difference between a picker
    /// that looks like nothing is selected and one that explains why.
    private var selectionIsMissingFromCatalog: Bool {
        guard case .loaded = catalogState, !isDefaulted, !models.isEmpty else { return false }
        return !models.contains { $0.selector == resolvedModel }
    }

    private var catalogStatus: (label: String, mode: StatusChip.Mode) {
        switch catalogState {
        case .idle:
            ("NOT LOADED", .neutral)
        case .loading:
            ("LOADING…", .neutral)
        case .loaded:
            models.isEmpty
                ? ("NO MODELS", .warn)
                : ("\(models.count) \(models.count == 1 ? "MODEL" : "MODELS")", .ok)
        case .failed:
            models.isEmpty ? ("CATALOG UNAVAILABLE", .warn) : ("CATALOG STALE", .warn)
        }
    }

    /// The cap has to state itself. A list that silently stops at eight is a
    /// list the user believes is complete. Every non-loaded catalog state says
    /// which one it is, because "no rows" has three very different causes.
    private func listSummary(shown: Int, matched: Int) -> String {
        switch catalogState {
        case .idle:
            return "The model list is inherited from `omp models`; REFRESH asks OMP again."
        case .loading:
            return "Asking OMP for its model list…"
        case .failed:
            return models.isEmpty
                ? "OMP's model list could not be read, so there is nothing to choose from yet."
                : "Showing the last list OMP returned; REFRESH to try again."
        case .loaded:
            break
        }
        if selectionIsMissingFromCatalog {
            return "\(resolvedModel) is not in OMP's list of \(models.count) models — pick one below."
        }
        guard !models.isEmpty else {
            return "OMP reported no models. Connect a provider above, then REFRESH."
        }
        guard matched > 0 else {
            return "No model matches \"\(filter)\" out of \(models.count) from OMP."
        }
        if matched > shown {
            return "Showing \(shown) of \(matched) matching models — filter to narrow the list."
        }
        return matched == models.count
            ? "Showing all \(matched) models OMP can reach."
            : "Showing \(matched) of \(models.count) models."
    }
}

/// One selectable model. The whole row is the control, so the hit target is the
/// row rather than a word inside it, and the interaction ladder is the shared
/// one every other selectable row in this app uses.
private struct OmpModelOptionRow: View {
    let title: String
    let detail: String
    let identifier: String
    let accessibilityLabel: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    private var a11y = A11y()

    init(
        title: String,
        detail: String,
        identifier: String,
        accessibilityLabel: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.identifier = identifier
        self.accessibilityLabel = accessibilityLabel
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: VoiceOourMetrics.Space.sm) {
                VStack(alignment: .leading, spacing: VoiceOourMetrics.Space.hair) {
                    Text(title)
                        .font(VoiceOourTypography.body)
                        .foregroundStyle(isEnabled ? VoiceOourPalette.Text.high : a11y.textLow)
                        .recordTextRole(
                            .body,
                            foreground: isEnabled ? VoiceOourPalette.Text.high : a11y.textLow
                        )
                    Text(detail)
                        .font(VoiceOourTypography.caption)
                        .foregroundStyle(a11y.textLow)
                        .recordTextRole(.caption, foreground: a11y.textLow)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: VoiceOourMetrics.Space.sm)

                if isSelected {
                    StatusChip(label: "IN USE", mode: .live, size: .compact)
                }
            }
            .padding(.horizontal, VoiceOourMetrics.Space.sm)
            .frame(maxWidth: .infinity, minHeight: VoiceOourMetrics.Row.list, alignment: .leading)
        }
        .buttonStyle(PlateButtonStyle(isSelected: isSelected))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
