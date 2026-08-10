// Prints the CGWindowID of VoiceOour's largest on-screen window (the console),
// or nothing if it is not open. Window ids/bounds/owner are available without
// Screen Recording permission; only pixel capture (screencapture) needs it.
import CoreGraphics
import Foundation

let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}

struct Candidate { let id: Int; let area: CGFloat }

let best = list.compactMap { info -> Candidate? in
    guard (info[kCGWindowOwnerName as String] as? String) == "VoiceOour" else { return nil }
    guard let id = info[kCGWindowNumber as String] as? Int else { return nil }
    // kCGWindowBounds is a toll-free-bridged dictionary of CFNumbers; parse it via
    // CGRect(dictionaryRepresentation:) rather than a fragile [String: CGFloat] cast.
    guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
    // Skip the menu-bar status item / tiny windows; the console is large.
    guard rect.height > 300 else { return nil }
    return Candidate(id: id, area: rect.width * rect.height)
}.max { $0.area < $1.area }

if let best {
    print(best.id)
}
