import SwiftUI

struct MenuBarLabel: View {
    /// The status dot sits in the system menu bar, outside the console's theme:
    /// the bar's own appearance follows the wallpaper, not the reader's console
    /// choice, so these stay fixed signal tints.
    private static let errorTint = Color(.sRGB, red: 0.98, green: 0.44, blue: 0.44, opacity: 1)
    private static let liveTint = Color(.sRGB, red: 0.62, green: 0.86, blue: 1.00, opacity: 1)
    private static let preparingTint = Color(.sRGB, red: 0.98, green: 0.78, blue: 0.42, opacity: 1)

    var coordinator: DictationCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Model acquisition is not a `SessionState`, so without a case of its own the
    /// icon sat at rest for however long 1.26 GB takes on a first run — the one
    /// window where nothing the reader tries can work. Amber matches the caution
    /// tone the menu's Preparing pill wears, and it ranks below both signals about
    /// a session the reader started: an error still shows crimson and a live
    /// session still shows cyan.
    private var isAcquiringModel: Bool {
        coordinator.modelDownloadFraction != nil || coordinator.isBackendWarming
    }

    private var dotColor: Color? {
        if coordinator.state.isCritical {
            Self.errorTint
        } else if coordinator.state.isActive {
            Self.liveTint
        } else if isAcquiringModel {
            Self.preparingTint
        } else {
            nil
        }
    }

    /// Deliberately not pulsing for acquisition: a repeatForever animation would run
    /// for the whole download.
    private var isPulsing: Bool {
        coordinator.state == .recording
    }

    private var accessibilityText: String {
        if coordinator.state.isCritical {
            "Voiceour: error"
        } else if coordinator.state == .recording {
            "Voiceour: recording"
        } else if coordinator.state.isActive {
            "Voiceour: working"
        } else if isAcquiringModel {
            "Voiceour: preparing the speech model"
        } else {
            "Voiceour: idle"
        }
    }

    var body: some View {
        Text("👽")
            .overlay(alignment: .bottomTrailing) {
                if let dotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(
                            width: VoiceourMetrics.Space.xs + VoiceourMetrics.Space.hair,
                            height: VoiceourMetrics.Space.xs + VoiceourMetrics.Space.hair
                        )
                        .scaleEffect(isPulsing && !reduceMotion ? 1.08 : 1.0)
                        .opacity(isPulsing ? 0.58 : 1.0)
                        .animation(
                            isPulsing && !reduceMotion
                                ? .easeInOut(duration: VoiceourMotion.livePulseDuration)
                                    .repeatForever(autoreverses: true)
                                : VoiceourMotion.quick,
                            value: isPulsing
                        )
                }
            }
            .accessibilityLabel(accessibilityText)
            // The menu bar label is hosted for the life of the process, so it is
            // where a request to show the console lands whether or not the window
            // is open: `--show-console` at launch, and a reopen of the running app.
            .onReceive(NotificationCenter.default.publisher(for: .voiceourShowConsole)) { _ in
                openWindow(id: ConsolePresentation.windowID)
                ConsolePresentation.show()
            }
    }
}
