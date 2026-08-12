// Offscreen UI harness. Compiled only when `UI_HARNESS` is defined.
//
// The flag comes from `scripts/ui_harness.sh` (and so every `make ui-*` target) and
// from the `make test` / CI `swift test` steps. Ordinary builds omit it, the
// `swift build -c release` inside `scripts/bundle.sh` that ships included -- which is
// the entire point: these objects used to link into the shipping binary even though
// execution was gated at runtime on `--ui-harness`.
//
// `RenderOverrides` is deliberately NOT here: many production files read it, so
// it lives in `Sources/VoiceOour/RenderOverrides.swift` and is never gated.
#if UI_HARNESS

    // MARK: - Line diff
    /// Minimal unified diff over accessibility dumps.
    ///
    /// The dumps are a few hundred lines, so a plain LCS table is cheap; the size guard only
    /// exists so a pathological input degrades to a positional listing instead of allocating
    /// hundreds of megabytes.
    enum UIHarnessDiff {
        private static let maximumCells = 4_000_000
        private static let contextLines = 3

        static func unified(old: [String], new: [String], oldLabel: String, newLabel: String) -> String {
            let header = "--- \(oldLabel)\n+++ \(newLabel)\n"
            guard old.count * new.count <= maximumCells else {
                return header + positional(old: old, new: new)
            }
            let entries = align(old: old, new: new)
            let hunks = group(entries)
            guard !hunks.isEmpty else { return header }
            return header + hunks.map { render($0, entries: entries) }.joined()
        }

        private enum Edit {
            case keep(String)
            case remove(String)
            case insert(String)

            var isChange: Bool {
                if case .keep = self { return false }
                return true
            }

            var body: String {
                switch self {
                case .keep(let line): line
                case .remove(let line): line
                case .insert(let line): line
                }
            }

            var marker: Character {
                switch self {
                case .keep: " "
                case .remove: "-"
                case .insert: "+"
                }
            }

            /// True when the line occupies a position in the golden file.
            var touchesOld: Bool {
                if case .insert = self { return false }
                return true
            }

            /// True when the line occupies a position in the current dump.
            var touchesNew: Bool {
                if case .remove = self { return false }
                return true
            }
        }

        private struct Entry {
            let edit: Edit
            let oldLine: Int
            let newLine: Int
        }

        // MARK: LCS

        private static func table(old: [String], new: [String]) -> [Int32] {
            let rows = old.count
            let columns = new.count
            var cells = [Int32](repeating: 0, count: (rows + 1) * (columns + 1))
            let rowStride = columns + 1
            for rowIndex in Swift.stride(from: rows - 1, through: 0, by: -1) {
                for columnIndex in Swift.stride(from: columns - 1, through: 0, by: -1) {
                    let base = rowIndex * rowStride + columnIndex
                    if old[rowIndex] == new[columnIndex] {
                        cells[base] = cells[base + rowStride + 1] + 1
                    } else {
                        cells[base] = max(cells[base + rowStride], cells[base + 1])
                    }
                }
            }
            return cells
        }

        private static func align(old: [String], new: [String]) -> [Entry] {
            guard !old.isEmpty else { return number(new.map(Edit.insert)) }
            guard !new.isEmpty else { return number(old.map(Edit.remove)) }
            let cells = table(old: old, new: new)
            let rowStride = new.count + 1
            var edits: [Edit] = []
            var oldIndex = 0
            var newIndex = 0
            while oldIndex < old.count && newIndex < new.count {
                if old[oldIndex] == new[newIndex] {
                    edits.append(.keep(old[oldIndex]))
                    oldIndex += 1
                    newIndex += 1
                } else if cells[(oldIndex + 1) * rowStride + newIndex] >= cells[oldIndex * rowStride + newIndex + 1] {
                    edits.append(.remove(old[oldIndex]))
                    oldIndex += 1
                } else {
                    edits.append(.insert(new[newIndex]))
                    newIndex += 1
                }
            }
            edits.append(contentsOf: old[oldIndex...].map(Edit.remove))
            edits.append(contentsOf: new[newIndex...].map(Edit.insert))
            return number(edits)
        }

        private static func number(_ edits: [Edit]) -> [Entry] {
            var entries: [Entry] = []
            entries.reserveCapacity(edits.count)
            var oldLine = 0
            var newLine = 0
            for edit in edits {
                switch edit {
                case .keep:
                    oldLine += 1
                    newLine += 1
                case .remove:
                    oldLine += 1
                case .insert:
                    newLine += 1
                }
                entries.append(Entry(edit: edit, oldLine: oldLine, newLine: newLine))
            }
            return entries
        }

        // MARK: Hunks

        private static func group(_ entries: [Entry]) -> [ClosedRange<Int>] {
            let changed = entries.indices.filter { entries[$0].edit.isChange }
            guard !changed.isEmpty else { return [] }
            var hunks: [ClosedRange<Int>] = []
            var lower = max(0, changed[0] - contextLines)
            var upper = min(entries.count - 1, changed[0] + contextLines)
            for index in changed.dropFirst() {
                if index - contextLines <= upper + 1 {
                    upper = min(entries.count - 1, index + contextLines)
                } else {
                    hunks.append(lower...upper)
                    lower = max(0, index - contextLines)
                    upper = min(entries.count - 1, index + contextLines)
                }
            }
            hunks.append(lower...upper)
            return hunks
        }

        private static func render(_ hunk: ClosedRange<Int>, entries: [Entry]) -> String {
            let slice = entries[hunk]
            let oldCount = slice.filter { $0.edit.touchesOld }.count
            let newCount = slice.filter { $0.edit.touchesNew }.count
            let oldStart = slice.first { $0.edit.touchesOld }?.oldLine ?? entries[hunk.lowerBound].oldLine
            let newStart = slice.first { $0.edit.touchesNew }?.newLine ?? entries[hunk.lowerBound].newLine
            let body = slice.map { "\($0.edit.marker)\($0.edit.body)\n" }.joined()
            return "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n" + body
        }

        private static func positional(old: [String], new: [String]) -> String {
            var body = "@@ positional listing: \(old.count) golden lines vs \(new.count) current lines @@\n"
            for index in 0..<max(old.count, new.count) {
                let before = index < old.count ? old[index] : nil
                let after = index < new.count ? new[index] : nil
                guard before != after else { continue }
                if let before { body += "-\(before)\n" }
                if let after { body += "+\(after)\n" }
            }
            return body
        }
    }

#endif
