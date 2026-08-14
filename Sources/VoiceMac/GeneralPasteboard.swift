import AppKit

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
    /// insertion adapter -- the menu's transcript copy, the Sessions transcript copy and
    /// `PropertyRow`'s value copy -- so a UI flow that presses one of them would clobber
    /// the clipboard of whoever is running the harness. That is not a golden churning; it
    /// is the harness reaching out of its box into the user's workspace, which the privacy
    /// rules forbid outright.
    ///
    /// Shaped like `RenderOverrides`: nil by default, every read is
    /// `override ?? <the real write>`, and nothing in production assigns it. Only
    /// `UI_HARNESS` code sets it, and only for the lifetime of one flow.
    public static var writeOverride: (@Sendable (String) -> Int)?

    /// Companion seam for `clearIfUnchanged`, so a harness flow can neither clear the real
    /// pasteboard nor read its real change count.
    public static var clearOverride: (@Sendable (Int) -> Bool)?

    /// Writes `text` as pasteboard content and returns the resulting change count.
    @discardableResult
    public static func copy(
        _ text: String,
        concealed: Bool = false,
        transient: Bool = false
    ) -> Int {
        if let writeOverride { return writeOverride(text) }
        let pasteboard = NSPasteboard.general
        var types = [NSPasteboard.PasteboardType.string]
        if concealed { types.append(concealedType) }
        if transient { types.append(transientType) }
        pasteboard.clearContents()
        pasteboard.declareTypes(types, owner: nil)
        pasteboard.setString(text, forType: .string)
        if concealed { pasteboard.setData(Data(), forType: concealedType) }
        if transient { pasteboard.setData(Data(), forType: transientType) }
        return pasteboard.changeCount
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
