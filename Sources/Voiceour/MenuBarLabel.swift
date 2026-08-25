import SwiftUI

struct MenuBarLabel: View {
    var coordinator: DictationCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dotColor: Color? {
        if coordinator.state.isCritical {
            VoiceourPalette.Signal.crimson
        } else if coordinator.state.isActive {
            VoiceourPalette.Signal.cyan
        } else {
            nil
        }
    }

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
