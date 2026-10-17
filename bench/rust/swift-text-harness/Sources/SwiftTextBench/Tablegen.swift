import Foundation

/// Dumps, for every Unicode scalar, the behaviour of the exact runtime the production
/// text path runs on (Swift stdlib `Character`/`String`, Foundation `CharacterSet`,
/// CoreFoundation folding/decomposition, and the system ICU behind
/// `NSRegularExpression`) as Rust source. The Rust port reads these tables instead of
/// its own Unicode data, so a property can only disagree if the port applies it wrongly.
enum Tablegen {
    private typealias HasProp = @convention(c) (Int32, Int32) -> Int8
    private typealias FoldCase = @convention(c) (Int32, UInt32) -> Int32
    private typealias StrFoldCase = @convention(c) (
        UnsafeMutablePointer<UInt16>?, Int32, UnsafePointer<UInt16>?, Int32, UInt32, UnsafeMutablePointer<Int32>
    ) -> Int32
    private typealias GetVersion = @convention(c) (UnsafeMutablePointer<UInt8>) -> Void

    static func run(outPath: String) throws {
        let icu = dlopen("/usr/lib/libicucore.A.dylib", RTLD_NOW)
        guard let icu else { throw HarnessError.message("cannot dlopen libicucore") }
        let foldCase = unsafeBitCast(dlsym(icu, "u_foldCase"), to: FoldCase.self)
        let strFoldCase = unsafeBitCast(dlsym(icu, "u_strFoldCase"), to: StrFoldCase.self)
        let getVersion = unsafeBitCast(dlsym(icu, "u_getVersion"), to: GetVersion.self)
        let getUnicodeVersion = unsafeBitCast(dlsym(icu, "u_getUnicodeVersion"), to: GetVersion.self)
        var icuVersion = [UInt8](repeating: 0, count: 4)
        var icuUnicode = [UInt8](repeating: 0, count: 4)
        getVersion(&icuVersion)
        getUnicodeVersion(&icuUnicode)

        let scalars = Probe.allScalars()
        let posix = Locale(identifier: "en_US_POSIX")
        let whitespaceRegex = try NSRegularExpression(pattern: #"\s"#)
        let wordClassRegex = try NSRegularExpression(pattern: #"(?i)[A-Za-z0-9_]"#)
        let lookbehindRegex = try NSRegularExpression(pattern: #"(?i)(?<![A-Za-z0-9_])b"#)
        let lookaheadRegex = try NSRegularExpression(pattern: #"(?i)b(?![A-Za-z0-9_])"#)

        var letter: [UInt32] = []
        var number: [UInt32] = []
        var whitespace: [UInt32] = []
        var upper: [UInt32] = []
        var lower: [UInt32] = []
        var wsnl: [UInt32] = []
        var punct: [UInt32] = []
        var symbol: [UInt32] = []
        var decimal: [UInt32] = []
        var alnum: [UInt32] = []
        var letters: [UInt32] = []
        var icuSpace: [UInt32] = []
        var icuWord: [UInt32] = []
        var cfNonBase: [UInt32] = []
        var lowerMap: [(UInt32, String)] = []
        var upperMap: [(UInt32, String)] = []
        var simpleFold: [(UInt32, UInt32)] = []
        var fullFold: [(UInt32, String)] = []
        var cfFold: [(UInt32, String)] = []
        var nfkdASCII: [(UInt32, String)] = []
        var lookaroundMismatch: [UInt32] = []

        for scalar in scalars {
            let value = scalar.value
            let string = String(scalar)
            let character = Character(scalar)
            if character.isLetter { letter.append(value) }
            if character.isNumber { number.append(value) }
            if character.isWhitespace { whitespace.append(value) }
            if character.isUppercase { upper.append(value) }
            if character.isLowercase { lower.append(value) }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { wsnl.append(value) }
            if CharacterSet.punctuationCharacters.contains(scalar) { punct.append(value) }
            if CharacterSet.symbols.contains(scalar) { symbol.append(value) }
            if CharacterSet.decimalDigits.contains(scalar) { decimal.append(value) }
            if CharacterSet.alphanumerics.contains(scalar) { alnum.append(value) }
            if CharacterSet.letters.contains(scalar) { letters.append(value) }

            let range = NSRange(location: 0, length: (string as NSString).length)
            if whitespaceRegex.firstMatch(in: string, range: range) != nil { icuSpace.append(value) }
            let inWord = wordClassRegex.firstMatch(in: string, range: range) != nil
            if inWord { icuWord.append(value) }
            // The probe letter must be matched at the position next to the scalar; for
            // `b`/`B` themselves another occurrence of the probe letter also matches.
            let behind = string + "b"
            let behindAccepts = lookbehindRegex.matches(
                in: behind, range: NSRange(location: 0, length: (behind as NSString).length)
            ).contains { $0.range.location == range.length }
            let ahead = "b" + string
            let aheadAccepts = lookaheadRegex.matches(
                in: ahead, range: NSRange(location: 0, length: (ahead as NSString).length)
            ).contains { $0.range.location == 0 }
            if behindAccepts == inWord || aheadAccepts == inWord { lookaroundMismatch.append(value) }

            if value != 0x0A, ("a\r" + string + "b").replacingOccurrences(of: "\r", with: "\n").unicodeScalars.contains("\r") {
                cfNonBase.append(value)
            }

            let lowered = string.lowercased()
            if !lowered.unicodeScalars.elementsEqual(string.unicodeScalars) { lowerMap.append((value, lowered)) }
            let uppered = string.uppercased()
            if !uppered.unicodeScalars.elementsEqual(string.unicodeScalars) { upperMap.append((value, uppered)) }

            let simple = UInt32(bitPattern: foldCase(Int32(bitPattern: value), 0))
            if simple != value { simpleFold.append((value, simple)) }
            let source = Array(string.utf16)
            var status: Int32 = 0
            var destination = [UInt16](repeating: 0, count: 16)
            let length = source.withUnsafeBufferPointer { src in
                strFoldCase(&destination, 16, src.baseAddress, Int32(src.count), 0, &status)
            }
            guard status <= 0, length >= 0 else { throw HarnessError.message("u_strFoldCase failed for \(value)") }
            let folded = String(decoding: destination[0..<Int(length)], as: UTF16.self)
            if !folded.unicodeScalars.elementsEqual(string.unicodeScalars) { fullFold.append((value, folded)) }

            let cf = string.folding(options: [.caseInsensitive], locale: posix)
            if !cf.unicodeScalars.elementsEqual(string.unicodeScalars) { cfFold.append((value, cf)) }

            if value >= 128 {
                let ascii = String(
                    String.UnicodeScalarView(string.decomposedStringWithCompatibilityMapping.unicodeScalars.filter { $0.value < 128 }))
                if !ascii.isEmpty { nfkdASCII.append((value, ascii)) }
            }
        }

        if !lookaroundMismatch.isEmpty {
            throw HarnessError.message("ICU lookaround differs from class membership for \(Probe.ranges(lookaroundMismatch))")
        }

        let age = Unicode.Scalar(0x20C1).flatMap(\.properties.age).map { "\($0.major).\($0.minor)" } ?? "<17"
        var out = """
            // @generated by `swift-text-bench tables` (bench/rust/swift-text-harness). DO NOT EDIT.
            // Source runtime: \(ProcessInfo.processInfo.operatingSystemVersionString); Swift stdlib Unicode
            // (U+20C1 age) \(age); ICU \(icuVersion.prefix(3).map(String.init).joined(separator: ".")) (Unicode \(icuUnicode.prefix(2).map(String.init).joined(separator: "."))).
            // Every table is observed behaviour of that runtime, scalar by scalar.
            #![allow(clippy::unreadable_literal)]

            """
        func emitSet(_ name: String, _ doc: String, _ values: [UInt32]) {
            out += "/// \(doc)\npub static \(name): &[(u32, u32)] = &[\n"
            var index = 0
            while index < values.count {
                var end = index
                while end + 1 < values.count, values[end + 1] == values[end] + 1 { end += 1 }
                out += "    (0x\(String(values[index], radix: 16, uppercase: true)), 0x\(String(values[end], radix: 16, uppercase: true))),\n"
                index = end + 1
            }
            out += "];\n\n"
        }
        func literal(_ string: String) -> String {
            var result = "\""
            for scalar in string.unicodeScalars {
                switch scalar {
                case "\"": result += "\\\""
                case "\\": result += "\\\\"
                default:
                    if scalar.value >= 0x20, scalar.value < 0x7F {
                        result.unicodeScalars.append(scalar)
                    } else {
                        result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
                    }
                }
            }
            return result + "\""
        }
        func emitMap(_ name: String, _ doc: String, _ entries: [(UInt32, String)]) {
            out += "/// \(doc)\npub static \(name): &[(u32, &str)] = &[\n"
            for (key, value) in entries {
                out += "    (0x\(String(key, radix: 16, uppercase: true)), \(literal(value))),\n"
            }
            out += "];\n\n"
        }

        emitSet("CHAR_LETTER", "`Character(scalar).isLetter` (Swift).", letter)
        emitSet("CHAR_NUMBER", "`Character(scalar).isNumber` (Swift).", number)
        emitSet("CHAR_WHITESPACE", "`Character(scalar).isWhitespace` (Swift).", whitespace)
        emitSet("CHAR_UPPER", "`Character(scalar).isUppercase` for a one-scalar Character (Swift).", upper)
        emitSet("CHAR_LOWER", "`Character(scalar).isLowercase` for a one-scalar Character (Swift).", lower)
        emitSet("FD_WHITESPACE_NEWLINE", "`CharacterSet.whitespacesAndNewlines` (Foundation).", wsnl)
        emitSet("FD_PUNCTUATION", "`CharacterSet.punctuationCharacters` (Foundation).", punct)
        emitSet("FD_SYMBOL", "`CharacterSet.symbols` (Foundation).", symbol)
        emitSet("FD_DECIMAL_DIGIT", "`CharacterSet.decimalDigits` (Foundation).", decimal)
        emitSet("FD_ALPHANUMERIC", "`CharacterSet.alphanumerics` (Foundation).", alnum)
        emitSet("FD_LETTER", "`CharacterSet.letters` (Foundation).", letters)
        emitSet("ICU_SPACE", "Scalars ICU's `\\s` matches (NSRegularExpression).", icuSpace)
        emitSet(
            "ICU_WORD_CASE_INSENSITIVE",
            "Scalars `(?i)[A-Za-z0-9_]` matches, which is also exactly what the alias look-behind and look-ahead reject.",
            icuWord)
        emitSet(
            "CF_NON_BASE",
            "Scalars after which `replacingOccurrences(of: \"\\r\")`/`(of: \"\\r\\n\")` refuses a match (CoreFoundation composed-sequence boundary).",
            cfNonBase)
        emitMap("LOWER_MAP", "`String(scalar).lowercased()` where it differs from the scalar (Swift).", lowerMap)
        emitMap("UPPER_MAP", "`String(scalar).uppercased()` where it differs from the scalar (Swift).", upperMap)
        out += "/// ICU `u_foldCase(c, U_FOLD_CASE_DEFAULT)` (simple folding) where it differs from `c`.\npub static ICU_SIMPLE_FOLD: &[(u32, u32)] = &[\n"
        for (key, value) in simpleFold {
            out += "    (0x\(String(key, radix: 16, uppercase: true)), 0x\(String(value, radix: 16, uppercase: true))),\n"
        }
        out += "];\n\n"
        emitMap("ICU_FULL_FOLD", "ICU `u_strFoldCase` of one scalar (full folding) where it differs from the scalar.", fullFold)
        emitMap(
            "CF_FOLD",
            "`String(scalar).folding(options: .caseInsensitive, locale: en_US_POSIX)` where it differs (Foundation).",
            cfFold)
        emitMap(
            "NFKD_ASCII",
            "ASCII scalars of `decomposedStringWithCompatibilityMapping` for each non-ASCII scalar that has any (Foundation).",
            nfkdASCII)

        try out.write(toFile: outPath, atomically: true, encoding: .utf8)
        print(
            "wrote \(outPath): letter \(letter.count) number \(number.count) ws \(whitespace.count) upper \(upper.count) lower \(lower.count) icuSpace \(icuSpace.count) icuWord \(icuWord.count) cfNonBase \(cfNonBase.count) lowerMap \(lowerMap.count) upperMap \(upperMap.count) simpleFold \(simpleFold.count) fullFold \(fullFold.count) cfFold \(cfFold.count) nfkdASCII \(nfkdASCII.count)"
        )
    }
}

enum HarnessError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let text): text
        }
    }
}
