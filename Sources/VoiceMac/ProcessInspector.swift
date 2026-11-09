import Darwin
import Foundation

/// What the kernel reports about one process: identity, terminal and start
/// time. Never its arguments or environment.
struct ProcessFacts: Equatable, Sendable {
    var pid: Int32
    var uid: UInt32
    var processGroup: Int32
    /// The foreground process group of the process's controlling terminal.
    var terminalForegroundGroup: Int32
    /// The controlling terminal's device; nil when the process has none.
    var terminalDevice: UInt32?
    /// The controlling terminal's name in `/dev`, such as `ttys003`.
    var terminalName: String?
    var startTime: Date
    /// Nil when the kernel cannot name the executable, as after it was
    /// replaced on disk.
    var executablePath: String?
    /// The process name, else its command name.
    var name: String
}

/// Reads process facts with libproc, in-process and without spawning anything.
///
/// Only the caller's own processes answer: for another user's process the
/// kernel refuses, and each function reports nothing. Nothing here reads
/// another process's arguments or environment.
enum ProcessInspector {
    /// The facts for `pid`; nil when it is not running or belongs to another
    /// user.
    static func facts(pid: Int32) -> ProcessFacts? {
        guard let info = bsdInfo(pid: pid) else { return nil }
        let device = terminalDevice(info)
        return ProcessFacts(
            pid: pid,
            uid: info.pbi_uid,
            processGroup: Int32(bitPattern: info.pbi_pgid),
            terminalForegroundGroup: Int32(bitPattern: info.e_tpgid),
            terminalDevice: device,
            terminalName: device.flatMap(terminalName),
            startTime: Date(
                timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                    + TimeInterval(info.pbi_start_tvusec) / 1_000_000
            ),
            executablePath: executablePath(pid: pid),
            name: {
                let name = string(info.pbi_name)
                return name.isEmpty ? string(info.pbi_comm) : name
            }()
        )
    }

    /// Paths of the files `pid` holds open; empty when they cannot be listed.
    static func openFilePaths(pid: Int32) -> [String] {
        guard pid > 0 else { return [] }
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Headroom for descriptors opened between the two calls.
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 32)
        let filled = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        var paths: [String] = []
        for descriptor in descriptors.prefix(Int(filled) / stride)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) > 0 else { continue }
            let path = string(info.pvip.vip_path)
            if !path.isEmpty {
                paths.append(path)
            }
        }
        return paths
    }

    /// The processes of user `uid` whose controlling terminal is `device`.
    static func pids(onTerminal device: UInt32, uid: UInt32) -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Headroom for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(count) + 128)
        let filled = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).filter { pid in
            guard let info = bsdInfo(pid: pid) else { return false }
            return info.pbi_uid == uid && terminalDevice(info) == device
        }
    }

    // MARK: Kernel reads

    private static func bsdInfo(pid: Int32) -> proc_bsdinfo? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_pid == UInt32(pid) else {
            return nil
        }
        return info
    }

    private static func terminalDevice(_ info: proc_bsdinfo) -> UInt32? {
        guard info.pbi_flags & UInt32(PROC_FLAG_CONTROLT) != 0, info.e_tdev != UInt32.max else { return nil }
        return info.e_tdev
    }

    private static func terminalName(_ device: UInt32) -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        let count = Int32(buffer.count)
        guard devname_r(dev_t(bitPattern: device), mode_t(S_IFCHR), &buffer, count) != nil else { return nil }
        let name = cString(buffer)
        return name.isEmpty || name == "??" ? nil : name
    }

    private static func executablePath(pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// The NUL-terminated string at the start of a fixed-size C buffer.
    private static func string<Buffer>(_ buffer: Buffer) -> String {
        withUnsafeBytes(of: buffer) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func cString(_ buffer: [CChar]) -> String {
        buffer.withUnsafeBytes { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
