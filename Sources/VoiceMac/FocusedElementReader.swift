import ApplicationServices
import Foundation

/// Role and title of an app's focused accessibility element.
struct FocusedElementFacts: Equatable, Sendable {
    var role: String?
    var title: String?
}

/// Reads which element of an app has keyboard focus, so binding can tell Tern's
/// terminal input from its other fields (docs/runtime.md › Agent session binding).
///
/// Read-only, and bounded: every call carries a messaging timeout, because the
/// default AX timeout against a hung app would outlast the whole binding budget.
/// Without Accessibility trust it answers nil and never prompts.
enum FocusedElementReader {
    static func read(pid: pid_t, timeout: Float = 0.25) -> FocusedElementFacts? {
        guard pid > 0, AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, timeout)
        var focused: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focused,
            CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, timeout)
        var role: CFTypeRef?
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        return FocusedElementFacts(role: role as? String, title: title as? String)
    }
}
