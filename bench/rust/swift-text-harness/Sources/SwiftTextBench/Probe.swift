import Foundation

/// One-off characterisations of Foundation/stdlib behaviours the Rust port must
/// reproduce. Each probe prints the scalars for which an observed behaviour departs
/// from a simple model, so the model can be refined until the list is empty.
enum Probe {
    static func allScalars() -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(0x110000)
        for value in 0...0x10FFFF {
            if let scalar = Unicode.Scalar(UInt32(value)) { out.append(scalar) }
        }
        return out
    }

    static func hex(_ s: String) -> String {
        s.unicodeScalars.map { String($0.value, radix: 16, uppercase: true) }.joined(separator: " ")
    }

    static func ranges(_ values: [UInt32]) -> String {
        var parts: [String] = []
        var index = 0
        while index < values.count {
            var end = index
            while end + 1 < values.count, values[end + 1] == values[end] + 1 { end += 1 }
            parts.append(
                values[index] == values[end]
                    ? String(values[index], radix: 16) : "\(String(values[index], radix: 16))-\(String(values[end], radix: 16))"
            )
            index = end + 1
        }
        return parts.joined(separator: " ")
    }

    static func run(_ which: String) {
        let scalars = allScalars()
        switch which {
        case "crlf":
            // normalize(): replacingOccurrences(of: "\r\n") then (of: "\r"). For which
            // neighbour scalars X is an occurrence NOT replaced?
            var rightCRLF: [UInt32] = []
            var leftCRLF: [UInt32] = []
            var rightCR: [UInt32] = []
            var leftCR: [UInt32] = []
            for x in scalars {
                let xs = String(x)
                if ("a\r\n" + xs + "b").replacingOccurrences(of: "\r\n", with: "\n").contains("\r\n") {
                    rightCRLF.append(x.value)
                }
                if ("a" + xs + "\r\nb").replacingOccurrences(of: "\r\n", with: "\n").contains("\r\n") {
                    leftCRLF.append(x.value)
                }
                if x != "\n", ("a\r" + xs + "b").replacingOccurrences(of: "\r", with: "\n").unicodeScalars.first(where: { $0 == "\r" }) != nil {
                    rightCR.append(x.value)
                }
                if ("a" + xs + "\rb").replacingOccurrences(of: "\r", with: "\n").unicodeScalars.contains("\r") {
                    leftCR.append(x.value)
                }
            }
            print("CRLF not replaced when followed by:", rightCRLF.count, ranges(rightCRLF).prefix(3000))
            print("CRLF not replaced when preceded by:", leftCRLF.count, ranges(leftCRLF).prefix(3000))
            print("CR not replaced when followed by:", rightCR.count, ranges(rightCR).prefix(3000))
            print("CR not replaced when preceded by:", leftCR.count, ranges(leftCR).prefix(3000))
            let icu = dlopen("/usr/lib/libicucore.A.dylib", RTLD_NOW)
            typealias HasProp = @convention(c) (Int32, Int32) -> Int8
            typealias IntProp = @convention(c) (Int32, Int32) -> Int32
            let hasProp = unsafeBitCast(dlsym(icu, "u_hasBinaryProperty"), to: HasProp.self)
            let intProp = unsafeBitCast(dlsym(icu, "u_getIntPropertyValue"), to: IntProp.self)
            let graphemeExtend = scalars.filter { hasProp(Int32($0.value), 11) != 0 }.map(\.value)
            let gcbExtendOrZWJ = scalars.filter { [3, 17].contains(intProp(Int32($0.value), 0x1012)) }.map(\.value)
            print("CRLF right == Grapheme_Extend:", rightCRLF == graphemeExtend, "== GCB Extend|ZWJ:", rightCRLF == gcbExtendOrZWJ)
            print("  only in CF set vs GE:", ranges(Array(Set(rightCRLF).subtracting(graphemeExtend)).sorted()))
            print("  only in GE vs CF set:", ranges(Array(Set(graphemeExtend).subtracting(rightCRLF)).sorted()))
            print("CR right == CRLF right:", rightCR == rightCRLF)
            print("CRLF not replaced when preceded by:", leftCRLF.count, ranges(leftCRLF))
            print("CR not replaced when preceded by:", leftCR.count, ranges(leftCR))
            for text in ["a\r\n\u{301}b", "a\r\nb", "a\r\n\u{200D}b", "a\r\u{200D}b", "a\r\n\u{301}\u{301}b", "\r\n\u{1F3FB}", "\r\n\u{FE0F}"] {
                print("  CR->LF on", hex(text), "=>", hex(text.replacingOccurrences(of: "\r", with: "\n")),
                      "| CRLF->LF =>", hex(text.replacingOccurrences(of: "\r\n", with: "\n")))
            }
        case "contains":
            // shouldSkipToken / fragileSurfaces: contains("/"), contains(" "), hasPrefix("-").
            // Model: Character-based (grapheme) comparison against the needle.
            var bad: [String] = []
            for x in scalars {
                let xs = String(x)
                for needle in ["/", " ", "~", "_"] {
                    for text in ["a" + needle + xs + "b", "a" + xs + needle + "b", xs + needle, needle + xs] {
                        let actual = text.contains(needle)
                        let model = Array(text).contains(Character(needle))
                        if actual != model { bad.append("contains(\(needle)) \(hex(text)) actual=\(actual)") }
                    }
                }
                for text in ["-" + xs + "b", xs + "-b", "-" + xs] {
                    let actual = text.hasPrefix("-")
                    let model = text.first == "-"
                    if actual != model { bad.append("hasPrefix(-) \(hex(text)) actual=\(actual)") }
                }
            }
            print("contains/hasPrefix model mismatches:", bad.count)
            for line in bad.prefix(40) { print("  ", line) }
        case "misc":
            let r = Range(NSRange(location: 0, length: 1), in: "a\u{301}b")
            var o = "a\u{301}b"
            if let r { o.replaceSubrange(r, with: "XY") }
            print("replaceSubrange non-aligned:", hex(o))
            let r2 = Range(NSRange(location: 1, length: 1), in: "a\u{301}b")
            print("Range(1,1) in a+acute+b:", String(describing: r2), r2.map { hex(String("a\u{301}b"[$0])) } ?? "nil")
            let emoji = "\u{1F600}x\u{1F600}"
            print("trim symbols emoji:", hex(emoji.trimmingCharacters(in: .symbols)))
            print("components punct supplementary:", "a\u{1F8B0}b\u{10100}c".components(separatedBy: .punctuationCharacters).map(hex))
            print("components ws supplementary:", "a\u{1680}b".components(separatedBy: .whitespacesAndNewlines).map(hex))
            print("Character(\"\\r\\n\").isWhitespace", Character("\r\n").isWhitespace, "isNewline", Character("\r\n").isNewline)
            let pairs: [(String, String)] = [("e\u{301}", "\u{E9}"), ("\u{212A}", "K"), ("a\u{328}\u{301}", "a\u{301}\u{328}")]
            for (a, b) in pairs { print("==", hex(a), hex(b), a == b, "<", a < b, b < a) }
            print("lower of Kelvin", hex("\u{212A}".lowercased()))
            print("compat decomposition fi ligature:", hex("\u{FB01}".decomposedStringWithCompatibilityMapping))
            print("split by space with nbsp:", "a\u{A0}b c".split(separator: " ").map { hex(String($0)) })
            print("CRLF char ==\\n?", Character("\r\n") == "\n")
        default:
            print("unknown probe \(which)")
        }
    }
}
