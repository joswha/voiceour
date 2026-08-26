// Prints the CGWindowID of Voiceour's largest on-screen window (the console),
// or, with `--rect`, that window's screen rectangle as `x,y,w,h` for
// `screencapture -R`. Nothing is printed if the window is not open. Window
// ids/bounds/owner are available without Screen Recording permission; only pixel
// capture (screencapture) needs it.
//
// `--pid N` narrows the search to one process. Owner name alone is ambiguous the
// moment a real Voiceour is already running — the developer's own menu-bar copy
// usually has the larger window, so an unscoped search photographs their live
// data instead of the instance the script just launched.
import CoreGraphics
import Foundation

var wantedPID: Int?
if let flag = CommandLine.arguments.firstIndex(of: "--pid"),
    let value = Int(CommandLine.arguments.dropFirst(flag + 1).first ?? "")
{
    wantedPID = value
}

let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}

struct Candidate { let id: Int; let rect: CGRect }

let best = list.compactMap { info -> Candidate? in
    if let wantedPID {
        guard (info[kCGWindowOwnerPID as String] as? Int) == wantedPID else { return nil }
    } else {
        guard (info[kCGWindowOwnerName as String] as? String) == "Voiceour" else { return nil }
    }
    guard let id = info[kCGWindowNumber as String] as? Int else { return nil }
    // kCGWindowBounds is a toll-free-bridged dictionary of CFNumbers; parse it via
    // CGRect(dictionaryRepresentation:) rather than a fragile [String: CGFloat] cast.
    guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
    // Skip the menu-bar status item / tiny windows; the console is large.
    guard rect.height > 300 else { return nil }
    return Candidate(id: id, rect: rect)
}.max { ($0.rect.width * $0.rect.height) < ($1.rect.width * $1.rect.height) }

guard let best else { exit(0) }

if CommandLine.arguments.contains("--rect") {
    let rect = best.rect
    print("\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))")
} else {
    print(best.id)
}
