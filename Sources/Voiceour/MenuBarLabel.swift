import SwiftUI

struct MenuBarLabel: View {
    var coordinator: DictationCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Model acquisition is not a `SessionState`, so without a case of its own the
    /// icon sat at rest for however long 1.26 GB takes on a first run — the one
    /// window where nothing the reader tries can work. Amber is the colour the menu
    /// and the System pane already give a PREPARING backend, and it ranks below both
    /// signals about a session the reader started: an error still shows crimson and a
    /// live session still shows cyan.
    private var isAcquiringModel: Bool {
        coordinator.modelDownloadFraction != nil || coordinator.isBackendWarming
    }

    private var dotColor: Color? {
        if coordinator.state.isCritical {
            VoiceourPalette.Signal.crimson
        } else if coordinator.state.isActive {
            VoiceourPalette.Signal.cyan
        } else if isAcquiringModel {
            VoiceourPalette.Signal.amber
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
