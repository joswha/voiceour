import Foundation

func parsedGlossaryAliases(_ text: String) -> [String] {
    var seen: Set<String> = []
    return
        text
        .split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { alias in
            guard !alias.isEmpty else { return false }
            return seen.insert(alias.lowercased()).inserted
        }
}
