import AppKit
import VoiceCore
import VoiceMac

/// What a surface shows for one persisted app reference: the friendliest name
/// available for it, and its icon when this Mac still has the app installed.
///
/// The bundle id stays the internal key everywhere — the ledger, the history
/// file, History's app filter — and only the display resolves through here.
struct AppIdentity {
    var label: String
    var icon: NSImage?

    /// Seam-aware entry point: the pinned catalog when the harness installed
    /// one, the live LaunchServices catalog otherwise.
    @MainActor
    static func resolve(bundleId: String?, persistedName: String?) -> AppIdentity {
        let installed: InstalledApp?
        if let pinned = RenderOverrides.installedApps {
            installed = bundleId.flatMap { pinned[$0] }
        } else {
            installed = InstalledAppCatalog.lookup(bundleId: bundleId)
        }
        return resolve(bundleId: bundleId, persistedName: persistedName, installed: installed)
    }

    /// The precedence, pure: the installed app's own name, else the name
    /// persisted with the row, else the bundle id humanized. An installed name
    /// wins on purpose — it is what the reader calls the app today, and a
    /// persisted snapshot can be months old.
    static func resolve(
        bundleId: String?,
        persistedName: String?,
        installed: InstalledApp?
    ) -> AppIdentity {
        AppIdentity(
            label: installed?.name ?? AppDisplayName.label(bundleId: bundleId, name: persistedName),
            icon: installed?.icon
        )
    }
}
