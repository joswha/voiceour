import Darwin
import Foundation
import Security
import Synchronization

/// Whether a running process and the `tern` executable Voiceour is about to
/// launch are Tern's own code (docs/runtime.md › Agent session binding).
///
/// A bundle id proves nothing — any app can declare `so.stencil.tern` — and a
/// child Voiceour launches runs under Voiceour's Microphone and Accessibility
/// grants, so nothing at `Contents/MacOS/tern` runs until both the running
/// process and that file satisfy Tern's designated requirement. Security.framework
/// code-signing calls only; no keychain API is involved.
enum TernSignature {
    /// Tern's identifier, anchored to Apple's developer CA and Tern's team.
    static let requirement =
        #"identifier "so.stencil.tern" and anchor apple generic and certificate leaf[subject.OU] = "VTLHGQC72S""#

    /// The file a static verdict was reached for. Replacing or rewriting the
    /// executable changes at least one of these, so a stale verdict is never
    /// reused for different bytes.
    private struct FileIdentity: Hashable {
        var device: dev_t
        var inode: ino_t
        var size: off_t
        var modifiedSeconds: Int
        var modifiedNanoseconds: Int
    }

    /// Static validation hashes the whole 160 MB executable (about 250 ms),
    /// which only a change to the file can change the answer to.
    private static let staticVerdicts = Mutex<[FileIdentity: Bool]>([:])

    /// True only when the process `pid` and the file at `executable` both
    /// satisfy `requirement`. Any failure to ask is a no.
    static func isGenuine(pid: pid_t, executable: URL) -> Bool {
        guard pid > 0, let requirement = compiledRequirement() else { return false }
        return runningCodeSatisfies(pid: pid, requirement) && staticCodeSatisfies(executable, requirement)
    }

    private static func compiledRequirement() -> SecRequirement? {
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess else {
            return nil
        }
        return compiled
    }

    /// Dynamic validation: the kernel still considers the process validly
    /// signed, and its code satisfies the requirement. Not cached — a pid is
    /// not an identity.
    private static func runningCodeSatisfies(pid: pid_t, _ requirement: SecRequirement) -> Bool {
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// A verdict is cached only when the file looked the same before and after
    /// validation, so a swap mid-check never caches an answer for the wrong file.
    private static func staticCodeSatisfies(_ executable: URL, _ requirement: SecRequirement) -> Bool {
        guard let before = fileIdentity(executable) else { return false }
        if let verdict = staticVerdicts.withLock({ $0[before] }) {
            return verdict
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code else {
            return false
        }
        let verdict = SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
        if fileIdentity(executable) == before {
            staticVerdicts.withLock { $0[before] = verdict }
        }
        return verdict
    }

    private static func fileIdentity(_ url: URL) -> FileIdentity? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return FileIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            size: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec
        )
    }
}
