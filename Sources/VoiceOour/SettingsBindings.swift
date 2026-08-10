import SwiftUI
import VoiceCore

/// Two-way binding into `DictationCoordinator.settings` that persists on every
/// write. Shared by every settings pane so a field never forgets to save.
@MainActor func settingBinding<Value>(
    _ coordinator: DictationCoordinator,
    _ keyPath: WritableKeyPath<VoiceCore.Settings, Value>
) -> Binding<Value> {
    Binding(
        get: { coordinator.settings[keyPath: keyPath] },
        set: { value in
            coordinator.settings[keyPath: keyPath] = value
            coordinator.saveSettings()
        }
    )
}
