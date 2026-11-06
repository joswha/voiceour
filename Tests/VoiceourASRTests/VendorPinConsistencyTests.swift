import Foundation
import Testing

@Suite("VendorPinConsistencyTests")
struct VendorPinConsistencyTests {
    @Test func packageNoticeAndVendorScriptUseTheSamePin() throws {
        let root = repoRoot()
        let package = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let notice = try String(
            contentsOf: root.appendingPathComponent("Vendor/ggml/NOTICE.md"),
            encoding: .utf8
        )
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/vendor_ggml.sh"),
            encoding: .utf8
        )

        let packagePin = try #require(
            commit(onLineContaining: "GGML_COMMIT", in: package),
            "Package.swift lacked GGML_COMMIT with an adjacent 40-hex commit"
        )
        let noticePin = try #require(
            commit(onLineContaining: "Commit", in: notice),
            "Vendor/ggml/NOTICE.md lacked Commit with an adjacent 40-hex commit"
        )
        let scriptPin = try #require(
            commit(onLineContaining: "PIN=", in: script),
            "scripts/vendor_ggml.sh lacked PIN= with an adjacent 40-hex commit"
        )

        #expect(packagePin == noticePin)
        #expect(noticePin == scriptPin)
    }

    private func commit(onLineContaining marker: String, in contents: String) -> String? {
        guard
            let line = contents.split(separator: "\n", omittingEmptySubsequences: false)
                .first(where: { $0.contains(marker) }),
            let range = line.range(of: #"\b[0-9a-f]{40}\b"#, options: .regularExpression)
        else {
            return nil
        }
        return String(line[range])
    }
}

func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
