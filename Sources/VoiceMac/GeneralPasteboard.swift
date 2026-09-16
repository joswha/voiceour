import AppKit
import Synchronization

/// Privacy-preserving write-only access to the general pasteboard.
/// Voiceour must never read, snapshot, or restore the user's prior clipboard contents.
public enum GeneralPasteboard {
    /// Clipboard-manager opt-out conventions. They are advisory because managers
    /// choose whether to honor them.
    public static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    public static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Offscreen-harness seam, `nil` in every shipping build.
    ///
    /// Three SwiftUI actions copy straight to the pasteboard rather than through the
    /// insertion adapter -- the menu's transcript copy, the History tab's transcript copy
    /// and the Settings tab's Copy Diagnostics -- so a UI flow that presses one of them would
    /// clobber the clipboard of whoever is running the harness. That is not a golden
    /// churning; it is the harness reaching out of its box into the user's workspace,
    /// which the privacy rules forbid outright.
    ///
    /// Nil by default; only harness code installs the replacement. The mutex protects
    /// installation and lookup, and the copied closure runs outside the lock.
    public static var writeOverride: (@Sendable (String) -> Int?)? {
        get { overrides.withLock { $0.write } }
        set { overrides.withLock { $0.write = newValue } }
    }

    /// Companion seam for `clearIfUnchanged`, so a harness flow can neither clear the real
    /// pasteboard nor read its real change count.
    public static var clearOverride: (@Sendable (Int) -> Bool)? {
        get { overrides.withLock { $0.clear } }
        set { overrides.withLock { $0.clear = newValue } }
    }

    private struct Overrides: Sendable {
        var write: (@Sendable (String) -> Int?)?
        var clear: (@Sendable (Int) -> Bool)?
    }

    private static let overrides = Mutex(Overrides())

    /// Writes the transcript and returns its prepared change count, or `nil` if
    /// the string or a required privacy marker could not be written. Failure can
    /// follow a partial write; callers must not paste, clear, or confirm success.
    ///
    /// Concealed copies are host-only; ordinary and transient copies keep the
    /// system's Universal Clipboard policy. Preparing contents clears the board
    /// without reading, retaining, or restoring anything previously copied.
    @discardableResult
    public static func copy(
        _ text: String,
        concealed: Bool = false,
        transient: Bool = false
    ) -> Int? {
        if let writeOverride { return writeOverride(text) }
        // Publish one complete item: no clipboard observer may see the text
        // before its concealed/transient opt-out markers are advertised.
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return nil }
        guard !concealed || item.setData(Data(), forType: concealedType) else { return nil }
        guard !transient || item.setData(Data(), forType: transientType) else { return nil }
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.prepareForNewContents(with: concealed ? .currentHostOnly : [])
        guard pasteboard.writeObjects([item]) else { return nil }
        return changeCount
    }

    /// Clears the pasteboard only if nothing else has written to it since `changeCount`.
    /// Used to drop dictated text after a successful paste without ever touching
    /// content another application placed on the pasteboard in the meantime.
    @discardableResult
    static func clearIfUnchanged(since changeCount: Int) -> Bool {
        if let clearOverride { return clearOverride(changeCount) }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == changeCount else { return false }
        pasteboard.clearContents()
        return true
    }
}
