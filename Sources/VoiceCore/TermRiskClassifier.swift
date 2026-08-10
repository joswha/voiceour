import Foundation

/// Deterministic, pure risk classifier for a term's stored canonical.
///
/// The classifier answers a single question the `RiskAuthorizer` needs before it
/// will ever consider an automatic edit: how harmful would a *wrong* automatic
/// replacement of this canonical be? It never inspects acoustics or confidence —
/// it looks only at the shape of the canonical string and fails safe toward the
/// stricter class when a shape is ambiguous.
///
/// - `.critical`: spans whose meaning is executable or addressable, where a wrong
///   automatic edit is materially harmful. Shell flags (`--force`), filesystem
///   paths (`src/main`), version/number strings (`v1.2.3`), and bare command-like
///   tokens (`kubectl`) all fall here. Lowercase single tokens are treated as
///   command-like on purpose: they are indistinguishable from shell commands, so
///   the safe direction is the strict band.
/// - `.medium`: multiword phrases and mixed-case product / API names (`OMPi`,
///   `NVIDIA Parakeet`, `NSPasteboard`). Still worth auto-correcting when the
///   evidence is strong, but not executable.
/// - `.low`: everything else — most notably bare acronyms (`API`, `URL`) — where
///   an incorrect edit is cosmetic.
public enum TermRiskClassifier {
    /// Classifies `canonical` by its textual shape. Total and side-effect free.
    public static func risk(for canonical: String) -> TermRisk {
        let trimmed = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .low }

        // Flags: a leading hyphen marks a command-line option (`-rf`, `--force`).
        if trimmed.hasPrefix("-") { return .critical }

        // Paths: a slash marks a filesystem or namespace path (`/usr/bin`).
        if trimmed.contains("/") { return .critical }

        // Versions / numbers: any digit marks a version string or numeric literal
        // whose exact value matters (`v1.2.3`, `3.14`, `macOS 26`).
        if trimmed.contains(where: { $0.isNumber }) { return .critical }

        // Multiword: a phrase / product name spanning several words (`NVIDIA
        // Parakeet`). Whitespace-only edge cases were trimmed away above.
        if trimmed.contains(where: { $0.isWhitespace }) { return .medium }

        let hasUppercase = trimmed.contains(where: { $0.isUppercase })
        let hasLowercase = trimmed.contains(where: { $0.isLowercase })

        // Mixed-case single tokens are product / API names (`OMPi`, `CGEvent`).
        if hasUppercase && hasLowercase { return .medium }

        // Command-like: a single token carrying lowercase letters but no uppercase
        // (`kubectl`, `grep`, `a.out`). Treated as executable and therefore strict.
        if hasLowercase { return .critical }

        // Everything left has no lowercase letters — bare acronyms (`API`, `URL`)
        // or symbol-only strings — where a wrong edit is cosmetic, not harmful.
        return .low
    }
}
