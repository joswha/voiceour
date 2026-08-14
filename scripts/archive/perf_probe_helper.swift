// perf_probe_helper — a tiny CGWindow/CGEvent CLI used by scripts/archive/perf_probe.sh to
// drive a repeatable render-performance measurement against a *running* VoiceOour.
//
// It reads window geometry (no permission needed) and synthesizes pointer activity
// (needs Accessibility "post events" access; the `preflight` command verifies it).
//
// Subcommands:
//   window                       -> prints "x y w h" of the largest on-screen VoiceOour
//                                   window (the console); exits 2 if none is open.
//   preflight                    -> prints "preflight=<bool> moved=<bool>"; exit 0 iff
//                                   event injection is permitted AND empirically moves
//                                   the cursor. Restores the cursor afterwards.
//   cursor                       -> prints the current cursor position as "x y".
//   move X Y                     -> posts one mouse-move event to restore a saved position.
//   sweep  X Y W H [SECONDS]      -> continuous Lissajous mouse-move sweeps across the
//                                   interior of rect (X,Y,W,H) for SECONDS (hover churn).
//   scroll X Y [SECONDS]          -> parks the cursor at (X,Y) then posts alternating
//                                   up/down scroll-wheel events for SECONDS.
// All motion commands snapshot the real cursor position and restore it at the end so
// the machine is left where the user had it.
import CoreGraphics
import Foundation

@inline(__always) func stderrLine(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func die(_ msg: String, _ code: Int32 = 1) -> Never { stderrLine(msg); exit(code) }

// Largest on-screen VoiceOour window (matches scripts/find_console_window.swift logic).
func consoleWindowRect() -> CGRect? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
    return list.compactMap { info -> (CGRect, CGFloat)? in
        guard (info[kCGWindowOwnerName as String] as? String) == "VoiceOour" else { return nil }
        guard let bd = info[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: bd as CFDictionary) else { return nil }
        guard r.height > 300 else { return nil }
        return (r, r.width * r.height)
    }.max { $0.1 < $1.1 }?.0
}

@inline(__always) func cursorLocation() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

@inline(__always) func moveMouse(_ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

let args = CommandLine.arguments
guard args.count >= 2 else { die("usage: window | preflight | cursor | move X Y | sweep X Y W H [secs] | scroll X Y [secs]") }

switch args[1] {
case "window":
    guard let r = consoleWindowRect() else { die("no-window", 2) }
    print("\(r.origin.x) \(r.origin.y) \(r.width) \(r.height)")

case "cursor":
    let point = cursorLocation()
    print("\(point.x) \(point.y)")

case "move":
    guard args.count >= 4, let x = Double(args[2]), let y = Double(args[3]) else {
        die("usage: move X Y")
    }
    moveMouse(CGPoint(x: x, y: y))

case "preflight":
    let pre = CGPreflightPostEventAccess()
    let before = cursorLocation()
    let target = CGPoint(x: before.x + 4, y: before.y + 4)
    moveMouse(target)
    usleep(80_000)
    let after = cursorLocation()
    let moved = abs(after.x - target.x) < 2 && abs(after.y - target.y) < 2
    moveMouse(before) // restore
    print("preflight=\(pre) moved=\(moved)")
    exit((pre && moved) ? 0 : 3)

case "sweep":
    guard args.count >= 6, let x = Double(args[2]), let y = Double(args[3]),
          let w = Double(args[4]), let h = Double(args[5]) else { die("usage: sweep X Y W H [secs]") }
    let secs = args.count >= 7 ? (Double(args[6]) ?? 10) : 10
    let rect = CGRect(x: x, y: y, width: w, height: h)
    // Stay off the menu bar / window chrome, sweep the tile content area.
    let inset = rect.insetBy(dx: rect.width * 0.10, dy: rect.height * 0.12)
    let start = cursorLocation()
    let t0 = Date()
    while true {
        let el = Date().timeIntervalSince(t0)
        if el >= secs { break }
        // Lissajous: fast horizontal serpentine, slow vertical drift -> broad hover churn.
        let hx = 0.5 - 0.5 * cos(el * 6.0)
        let vy = 0.5 - 0.5 * cos(el * 0.8)
        moveMouse(CGPoint(x: inset.minX + inset.width * hx, y: inset.minY + inset.height * vy))
        usleep(8_000) // ~125 moves/sec, dense enough to exercise a 120Hz display
    }
    moveMouse(start) // restore

case "scroll":
    guard args.count >= 4, let x = Double(args[2]), let y = Double(args[3]) else { die("usage: scroll X Y [secs]") }
    let secs = args.count >= 5 ? (Double(args[4]) ?? 10) : 10
    let start = cursorLocation()
    moveMouse(CGPoint(x: x, y: y)) // park over the console so scrolls target it
    usleep(50_000)
    let t0 = Date()
    var ticks = 0
    var up = true
    while true {
        if Date().timeIntervalSince(t0) >= secs { break }
        if ticks % 55 == 0 { up.toggle() } // flip direction ~every 0.55s for continuous redraw
        let delta: Int32 = up ? 28 : -28
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: delta, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
        usleep(10_000) // ~100 scroll events/sec
        ticks += 1
    }
    moveMouse(start) // restore

default:
    die("unknown command \(args[1])")
}
