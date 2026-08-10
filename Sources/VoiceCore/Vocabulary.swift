import Foundation

/// Provenance of a vocabulary term. Higher `trustRank` wins during compilation.
public enum TermSource: String, Codable, Equatable, Sendable, CaseIterable {
    case explicitCorrection
    case manualImport
    case appProfile
    case bundled

    /// Trust ordering: explicit user corrections dominate; bundled defaults are lowest.
    var trustRank: Int {
        switch self {
        case .explicitCorrection: 3
        case .manualImport: 2
        case .appProfile: 1
        case .bundled: 0
        }
    }
}

/// Where a term is eligible to activate.
public enum VocabularyScope: Codable, Equatable, Sendable {
    case global
    case bundleID(String)
    case projectID(String)

    enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case global
        case bundleID = "bundle_id"
        case projectID = "project_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .global:
            self = .global
        case .bundleID:
            self = .bundleID(try container.decode(String.self, forKey: .value))
        case .projectID:
            self = .projectID(try container.decode(String.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .global:
            try container.encode(Kind.global, forKey: .kind)
        case .bundleID(let value):
            try container.encode(Kind.bundleID, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .projectID(let value):
            try container.encode(Kind.projectID, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

/// An observed surface form that may be confirmed or rejected by the user.
public struct AliasLabel: Codable, Equatable, Sendable {
    public var surface: String
    public var confirmedAt: Date?
    public var rejectedAt: Date?

    enum CodingKeys: String, CodingKey {
        case surface
        case confirmedAt = "confirmed_at"
        case rejectedAt = "rejected_at"
    }

    public init(surface: String, confirmedAt: Date? = nil, rejectedAt: Date? = nil) {
        self.surface = surface
        self.confirmedAt = confirmedAt
        self.rejectedAt = rejectedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        surface = try container.decodeIfPresent(String.self, forKey: .surface) ?? ""
        confirmedAt = try container.decodeIfPresent(Date.self, forKey: .confirmedAt)
        rejectedAt = try container.decodeIfPresent(Date.self, forKey: .rejectedAt)
    }
}

/// An in-memory-only candidate captured from live context. Never persisted.
public struct EphemeralContextCandidate: Equatable, Sendable {
    public let id: String
    public let surface: String
    public let phones: [String]
    public let capturedBundleId: String?

    public init(id: String, surface: String, phones: [String] = [], capturedBundleId: String? = nil) {
        self.id = id
        self.surface = surface
        self.phones = phones
        self.capturedBundleId = capturedBundleId
    }
}

/// An immutable, ordered view of vocabulary active for one capture context.
public struct VocabularySnapshot: Equatable, Sendable {
    public let terms: [ProtectedTerm]
    public let ephemeral: [EphemeralContextCandidate]
    public let capturedBundleId: String?
    public let generatedAt: Date

    public init(
        terms: [ProtectedTerm],
        ephemeral: [EphemeralContextCandidate],
        capturedBundleId: String?,
        generatedAt: Date
    ) {
        self.terms = terms
        self.ephemeral = ephemeral
        self.capturedBundleId = capturedBundleId
        self.generatedAt = generatedAt
    }
}

/// Deterministic, total compiler that folds persistent + ephemeral vocabulary
/// into a single trust-ordered, capped snapshot for one capture context.
public enum VocabularyCompiler {
    /// Per-source ceilings applied to non-priority terms so no single lower-trust
    /// source can crowd out the budget. Priority terms bypass quotas.
    private static let sourceQuota: [TermSource: Int] = [
        .explicitCorrection: Int.max,
        .manualImport: 60,
        .appProfile: 40,
        .bundled: 40,
    ]

    public static func compile(
        persistent: [ProtectedTerm],
        ephemeral: [EphemeralContextCandidate],
        capturedBundleId: String?,
        activeProjectId: String?,
        limit: Int = 100,
        now: Date = Date()
    ) -> VocabularySnapshot {
        let activated = persistent.enumerated().filter { _, term in
            (term.tombstonedAt.map { $0 > now } ?? true)
                && isActive(scope: term.scope, bundleId: capturedBundleId, projectId: activeProjectId)
        }

        // Stable ordering: trust desc, recency desc, then original index for determinism.
        let ordered = activated.sorted { lhs, rhs in
            let lt = lhs.element.source.trustRank
            let rt = rhs.element.source.trustRank
            if lt != rt { return lt > rt }
            let lr = recency(of: lhs.element)
            let rr = recency(of: rhs.element)
            if lr != rr { return lr > rr }
            return lhs.offset < rhs.offset
        }.map(\.element)

        let effectiveLimit = max(0, limit)
        var selected: [ProtectedTerm] = []
        var perSource: [TermSource: Int] = [:]
        var deferred: [ProtectedTerm] = []

        // Pass 1: priority terms (explicit corrections + pinned/protected) always
        // kept, reserving their room in the budget.
        for term in ordered where isPriority(term) {
            guard selected.count < effectiveLimit else { break }
            selected.append(term)
        }

        // Pass 2: fill remaining budget with quota-limited non-priority terms.
        for term in ordered where !isPriority(term) {
            guard selected.count < effectiveLimit else { break }
            let used = perSource[term.source] ?? 0
            let quota = sourceQuota[term.source] ?? Int.max
            if used < quota {
                perSource[term.source] = used + 1
                selected.append(term)
            } else {
                deferred.append(term)
            }
        }

        // Pass 3: if quotas left the budget under-filled, backfill in trust order.
        if selected.count < effectiveLimit {
            for term in deferred {
                guard selected.count < effectiveLimit else { break }
                selected.append(term)
            }
        }

        return VocabularySnapshot(
            terms: selected,
            ephemeral: ephemeral,
            capturedBundleId: capturedBundleId,
            generatedAt: now
        )
    }

    private static func isPriority(_ term: ProtectedTerm) -> Bool {
        term.source == .explicitCorrection || term.protected
    }

    private static func isActive(scope: VocabularyScope, bundleId: String?, projectId: String?) -> Bool {
        switch scope {
        case .global:
            true
        case .bundleID(let id):
            bundleId == id
        case .projectID(let id):
            projectId == id
        }
    }

    /// Recency proxy: latest confirmation across the term's active aliases.
    private static func recency(of term: ProtectedTerm) -> Date {
        var latest = Date.distantPast
        for alias in term.labeledAliases where alias.rejectedAt == nil {
            if let confirmed = alias.confirmedAt, confirmed > latest {
                latest = confirmed
            }
        }
        return latest
    }
}

/// Deterministic, total sanitizer that strips injection-relevant code points and
/// prompt-delimiter runs from vocabulary surface strings before they reach a model.
public enum VocabularySanitizer {
    /// Returns `true` when `raw` contains no forbidden code points or delimiters.
    public static func isSafe(_ raw: String) -> Bool {
        if raw.contains("`") || raw.contains("<") || raw.contains(">") {
            return false
        }
        for scalar in raw.unicodeScalars where isForbidden(scalar) {
            return false
        }
        return true
    }

    /// Removes forbidden code points and prompt-delimiter runs, trims whitespace,
    /// and returns `nil` when nothing usable remains.
    public static func sanitize(_ raw: String) -> String? {
        // Drop `<...>` runs, then any stray angle brackets and backticks.
        var stripped = ""
        stripped.reserveCapacity(raw.count)
        var depth = 0
        for character in raw {
            if character == "<" {
                depth += 1
                continue
            }
            if character == ">" {
                if depth > 0 { depth -= 1 }
                continue
            }
            if depth > 0 { continue }
            if character == "`" { continue }
            stripped.append(character)
        }

        var cleaned = String.UnicodeScalarView()
        for scalar in stripped.unicodeScalars where !isForbidden(scalar) {
            cleaned.append(scalar)
        }

        let result = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        // C0 controls + DEL.
        if value <= 0x1F || value == 0x7F { return true }
        // C1 controls.
        if (0x80...0x9F).contains(value) { return true }
        // Bidirectional controls.
        if bidiControls.contains(value) { return true }
        if (0x202A...0x202E).contains(value) { return true }
        if (0x2066...0x2069).contains(value) { return true }
        // Default-ignorable code points commonly abused for spoofing.
        if defaultIgnorable.contains(value) { return true }
        if (0xFE00...0xFE0F).contains(value) { return true }  // variation selectors
        if (0xE0000...0xE007F).contains(value) { return true }  // tag characters
        return false
    }

    private static let bidiControls: Set<UInt32> = [0x200E, 0x200F, 0x061C]
    private static let defaultIgnorable: Set<UInt32> = [
        0x00AD,  // soft hyphen
        0x034F,  // combining grapheme joiner
        0x061C,  // arabic letter mark
        0x115F, 0x1160,  // hangul fillers
        0x17B4, 0x17B5,  // khmer vowel inherent
        0x180E,  // mongolian vowel separator
        0x200B, 0x200C, 0x200D,  // zero-width space/non-joiner/joiner
        0x2060,  // word joiner
        0x2061, 0x2062, 0x2063, 0x2064,  // invisible math operators
        0xFEFF,  // zero-width no-break space / BOM
        0xFFF9, 0xFFFA, 0xFFFB,  // interlinear annotation
    ]
}
