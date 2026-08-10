import AppKit
import SwiftUI

struct MenuBarLabel: View {
    var coordinator: DictationCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dotColor: Color? {
        if coordinator.state.isCritical {
            VoiceOourPalette.Signal.crimson
        } else if coordinator.state.isActive {
            VoiceOourPalette.Signal.cyan
        } else {
            nil
        }
    }

    private var isPulsing: Bool {
        coordinator.state == .recording
    }

    private var accessibilityText: String {
        if coordinator.state.isCritical {
            "VoiceOour: error"
        } else if coordinator.state == .recording {
            "VoiceOour: recording"
        } else if coordinator.state.isActive {
            "VoiceOour: working"
        } else {
            "VoiceOour: idle"
        }
    }

    var body: some View {
        Text("👽")
            .overlay(alignment: .bottomTrailing) {
                if let dotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(
                            width: VoiceOourMetrics.Space.xs + VoiceOourMetrics.Space.hair,
                            height: VoiceOourMetrics.Space.xs + VoiceOourMetrics.Space.hair
                        )
                        .scaleEffect(isPulsing && !reduceMotion ? 1.08 : 1.0)
                        .opacity(isPulsing ? 0.58 : 1.0)
                        .animation(
                            isPulsing && !reduceMotion
                                ? .easeInOut(duration: 1.6).repeatForever(autoreverses: true)
                                : VoiceOourMotion.quick,
                            value: isPulsing
                        )
                }
            }
            .accessibilityLabel(accessibilityText)
            .onReceive(NotificationCenter.default.publisher(for: .voiceOourShowConsole)) { _ in
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}
