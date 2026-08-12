// Offscreen UI harness. Compiled only when `UI_HARNESS` is defined.
//
// The flag comes from `scripts/ui_harness.sh` (and so every `make ui-*` target) and
// from the `make test` / CI `swift test` steps. Ordinary builds omit it, the
// `swift build -c release` inside `scripts/bundle.sh` that ships included -- which is
// the entire point: these objects used to link into the shipping binary even though
// execution was gated at runtime on `--ui-harness`.
//
// `RenderOverrides` is deliberately NOT here: many production files read it, so
// it lives in `Sources/VoiceOour/RenderOverrides.swift` and is never gated.
#if UI_HARNESS

    import Darwin
    import Dispatch
    import Foundation
    import SwiftUI
    // MARK: - Reporting

    extension UIHarnessMain {
        static func summarise(_ outcomes: [UISceneOutcome], request: UIHarnessRequest) {
            // `--stdout` hands stdout to the machine, so the prose moves to stderr and the
            // manifest stays parseable as NDJSON.
            let machineMode = request.stdoutManifest
            for outcome in outcomes where outcome.result.status != .ok {
                note(sceneLine(outcome), machineMode: machineMode)
            }
            for outcome in outcomes {
                for finding in outcome.result.findings where finding.severity == .error {
                    report(
                        "\(finding.severity.rawValue) \(outcome.result.scene.id) \(finding.rule): \(finding.message)")
                }
            }
            note("\(tool): \(tallyLine(tally(outcomes)))", machineMode: machineMode)
            note("\(tool): artifacts \(request.outputDirectory.path)", machineMode: machineMode)
        }

        private static func sceneLine(_ outcome: UISceneOutcome) -> String {
            let result = outcome.result
            if let error = result.error {
                return "\(tool): failed \(result.scene.id) \(error)"
            }
            let pixel = statusLabel(result.pixelStatus)
            let axState = statusLabel(result.axStatus)
            return "\(tool): \(statusLabel(result.status)) \(result.scene.id) pixel=\(pixel) ax=\(axState)"
        }

        private static func tallyLine(_ counts: UITally) -> String {
            var parts = ["\(counts.total) scene\(counts.total == 1 ? "" : "s")", "\(counts.ok) ok"]
            if counts.changed > 0 { parts.append("\(counts.changed) changed") }
            if counts.missingGolden > 0 { parts.append("\(counts.missingGolden) missing-golden") }
            if counts.written > 0 { parts.append("\(counts.written) written") }
            if counts.failed > 0 { parts.append("\(counts.failed) failed") }
            if counts.errorFindings > 0 { parts.append("\(counts.errorFindings) lint-errors") }
            if counts.warningFindings > 0 { parts.append("\(counts.warningFindings) lint-warnings") }
            return parts.joined(separator: ", ")
        }

        static func tally(_ outcomes: [UISceneOutcome]) -> UITally {
            var counts = UITally()
            counts.total = outcomes.count
            for outcome in outcomes {
                switch outcome.result.status {
                case .ok: counts.ok += 1
                case .changed: counts.changed += 1
                case .missingGolden: counts.missingGolden += 1
                case .written: counts.written += 1
                case .failed: counts.failed += 1
                }
                counts.errorFindings += outcome.result.findings.filter { $0.severity == .error }.count
                counts.warningFindings += outcome.result.findings.filter { $0.severity == .warning }.count
            }
            return counts
        }

        static func hasFailure(_ outcomes: [UISceneOutcome]) -> Bool {
            outcomes.contains { outcome in
                let status = outcome.result.status
                return (status != .ok && status != .written)
                    || outcome.result.findings.contains { $0.severity == .error }
            }
        }

        /// Pure vocabulary mapping, so the manifest row initialisers -- which are plain
        /// `Encodable` value types outside the main actor -- can share this one spelling
        /// instead of growing a second copy that drifts.
        nonisolated static func statusLabel(_ status: UISceneResult.Status) -> String {
            status == .missingGolden ? "missing-golden" : status.rawValue
        }

        /// `--stdout` hands stdout to the machine, so prose moves to stderr. Shared by every
        /// mode's summary rather than respelled per mode.
        static func note(_ message: String, machineMode: Bool) {
            if machineMode {
                fputs("\(message)\n", stderr)
            } else {
                print(message)
            }
        }

        @discardableResult
        static func report(_ message: String) -> Bool {
            fputs("\(tool): \(message)\n", stderr)
            return false
        }

        static func elapsedMs(since start: DispatchTime) -> Int {
            Int((DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
        }

        static func describe(_ error: Error) -> String {
            let nsError = error as NSError
            let cocoaish =
                nsError.domain == NSCocoaErrorDomain
                || nsError.domain == NSPOSIXErrorDomain
                || nsError.domain == NSOSStatusErrorDomain
            return cocoaish ? nsError.localizedDescription : String(describing: error)
        }

        static func stepText(_ step: UIStep) -> String {
            switch step {
            case .press(let target): "press:\(target)"
            case .click(let target): "click:\(target)"
            case .type(let text, into: let target): "type:\(target):\(text)"
            case .settle(let milliseconds): "settle:\(milliseconds)"
            }
        }

        static func schemeName(_ scheme: ColorScheme) -> String {
            switch scheme {
            case .dark: "dark"
            case .light: "light"
            @unknown default: "unknown"
            }
        }
    }
    struct UITally {
        var total = 0
        var ok = 0
        var changed = 0
        var missingGolden = 0
        var written = 0
        var failed = 0
        var errorFindings = 0
        var warningFindings = 0
    }

#endif
