import Foundation
import Testing

@testable import VoiceCore
@testable import VoiceMac

/// The coordinator gates refinement with `DictationPolicy.refinementDecision`
/// before dispatching, and every backend gates again with
/// `RefinerPolicy.preflightSkipReason` before touching a network, a subprocess,
/// or the on-device model. Those two used to be independent implementations of
/// "may we refine this?" that happened to agree.
///
/// They now share one implementation, and this pins the agreement so a future
/// edit to either side cannot reintroduce the drift. The strings are asserted
/// literally because they surface in the UI and in `RefinementTrace`.
@Suite("Refinement preflight agreement")
struct RefinementPreflightAgreementTests {
    private struct Gate {
        let name: String
        let enabled: Bool
        let safety: TargetSafetyClass
        let configured: Bool
        let expected: String?
    }

    private let gates: [Gate] = [
        Gate(name: "disabled", enabled: false, safety: .normalText, configured: true, expected: "disabled"),
        Gate(name: "unsafe target", enabled: true, safety: .terminal, configured: true, expected: "unsafe_target"),
        Gate(name: "unconfigured", enabled: true, safety: .normalText, configured: false, expected: "unconfigured"),
        Gate(name: "eligible", enabled: true, safety: .normalText, configured: true, expected: nil),
    ]

    @Test func coreAndBackendPreflightsAgreeOnEveryGateState() {
        for gate in gates {
            let core = DictationPolicy.refinementPreflight(
                refinerEnabled: gate.enabled,
                targetSafety: gate.safety,
                refinerConfigured: gate.configured
            )
            let backend = RefinerPolicy.preflightSkipReason(
                enabled: gate.enabled,
                safety: gate.safety,
                isConfigured: gate.configured
            )

            #expect(core == gate.expected, "core preflight disagreed on \(gate.name)")
            #expect(backend == gate.expected, "backend preflight disagreed on \(gate.name)")
        }
    }

    /// `unknownRisky` is copy-only for insertion but still refinable: the text is
    /// rewritten before anyone decides how to deliver it.
    @Test func unknownRiskyTargetsAreStillRefinable() {
        #expect(
            DictationPolicy.refinementPreflight(
                refinerEnabled: true,
                targetSafety: .unknownRisky,
                refinerConfigured: true
            ) == nil
        )
        #expect(
            RefinerPolicy.preflightSkipReason(enabled: true, safety: .unknownRisky, isConfigured: true) == nil
        )
    }

    @Test func secureAndCodeEditorTargetsAreRefusedByBothSides() {
        for safety in [TargetSafetyClass.secure, .codeEditor, .terminal] {
            #expect(
                DictationPolicy.refinementPreflight(
                    refinerEnabled: true,
                    targetSafety: safety,
                    refinerConfigured: true
                ) == "unsafe_target"
            )
            #expect(
                RefinerPolicy.preflightSkipReason(enabled: true, safety: safety, isConfigured: true) == "unsafe_target"
            )
        }
    }

    /// Precedence matters: a disabled refiner reports `disabled` even when the
    /// target is also unsafe and the provider also unconfigured, because that is
    /// the reason the user can act on.
    @Test func disabledOutranksEveryOtherGate() {
        #expect(
            DictationPolicy.refinementPreflight(
                refinerEnabled: false,
                targetSafety: .secure,
                refinerConfigured: false
            ) == "disabled"
        )
        #expect(
            RefinerPolicy.preflightSkipReason(enabled: false, safety: .secure, isConfigured: false) == "disabled"
        )
    }
}
