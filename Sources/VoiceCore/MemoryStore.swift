import Foundation

/// Everything one change writes, computed off the main actor from two complete states.
public struct MemoryWrite: Equatable, Sendable {
    /// Month key `YYYY-MM` to that month's complete entries; an empty array removes the file.
    public var months: [String: [MemoryEntry]]
    /// Non-nil rewrites `topics.json`; an empty array removes it.
    public var topics: [MemoryTopic]?
    /// Pages to write.
    public var pages: [MemoryPage]
    /// Paths relative to the memory root to remove.
    public var removedPages: [String]
    /// Also removes every derived page that `pages` does not name, so a rebuild
    /// leaves no page of an older layout or another time zone behind.
    public var sweepDerived: Bool
    /// Non-nil writes `pages-format` after everything else succeeded, so the
    /// stamp names a format only once every page of it is on disk.
    public var pagesFormat: String?

    public init(
        months: [String: [MemoryEntry]] = [:],
        topics: [MemoryTopic]? = nil,
        pages: [MemoryPage] = [],
        removedPages: [String] = [],
        sweepDerived: Bool = false,
        pagesFormat: String? = nil
    ) {
        self.months = months
        self.topics = topics
        self.pages = pages
        self.removedPages = removedPages
        self.sweepDerived = sweepDerived
        self.pagesFormat = pagesFormat
    }

    public var isEmpty: Bool {
        months.isEmpty && topics == nil && pages.isEmpty && removedPages.isEmpty && !sweepDerived
            && pagesFormat == nil
    }
}

/// What the memory folder holds, as far as it could be read.
public struct MemoryLoad: Equatable, Sendable {
    /// Oldest first.
    public var entries: [MemoryEntry]
    public var topics: [MemoryTopic]
    /// Files that exist and could not be decoded; nothing was read from them,
    /// so a caller must not overwrite them with what it believes they held.
    public var unreadable: [URL]

    public init(entries: [MemoryEntry] = [], topics: [MemoryTopic] = [], unreadable: [URL] = []) {
        self.entries = entries
        self.topics = topics
        self.unreadable = unreadable
    }
}

/// The durable, uncapped memory folder: one JSON file per month as the source
/// of truth, a topics file, and the Markdown pages derived from them.
///
/// Every file is owner-only, because the folder holds everything the user said;
/// `agents/` belongs to the agents that read the folder and this store only
/// ever removes it, with the rest of the root, on `clear()`.
public struct MemoryStore: Sendable {
    public var root: URL

    public init(root: URL = MemoryStore.defaultRoot) {
        self.root = root
    }

    public static var defaultRoot: URL {
        URL.voiceourSupportDirectory().appendingPathComponent("memory", isDirectory: true)
    }

    public var entriesDirectory: URL {
        root.appendingPathComponent("entries", isDirectory: true)
    }

    public var topicsURL: URL {
        root.appendingPathComponent("topics.json")
    }

    /// Written by agents, never by this store.
    public var agentsDirectory: URL {
        root.appendingPathComponent("agents", isDirectory: true)
    }

    /// The format, calendar and zone of the derived pages on disk. No diff
    /// write touches it, so it changes only when a whole rebuild finished.
    public var pagesFormatURL: URL {
        root.appendingPathComponent("pages-format")
    }

    /// The folders whose pages a sweep may remove; nothing else ever is.
    static let derivedPageFolders = ["days", "threads", "topics", "notes"]

    public func monthURL(_ month: String) -> URL {
        entriesDirectory.appendingPathComponent("\(month).json")
    }

    /// `YYYY-MM` in `calendar`'s time zone, so an entry made late on the last
    /// evening of a month files under the month the user lived it in.
    public static func monthKey(for date: Date, calendar: Calendar) -> String {
        MemoryDateText.month(date, calendar: calendar)
    }

    /// Never throws: an absent root is an empty load, and a file that cannot be
    /// decoded is reported in `unreadable` while every other file still loads.
    public func load() -> MemoryLoad {
        let fileManager = FileManager.default
        let decoder = Self.makeDecoder()
        var load = MemoryLoad()

        if fileManager.fileExists(atPath: entriesDirectory.path) {
            do {
                let names = try fileManager.contentsOfDirectory(atPath: entriesDirectory.path)
                var entries: [MemoryEntry] = []
                for name in names.filter({ $0.hasSuffix(".json") }).sorted() {
                    let url = entriesDirectory.appendingPathComponent(name)
                    do {
                        entries += try decoder.decode([MemoryEntry].self, from: Data(contentsOf: url))
                    } catch {
                        load.unreadable.append(url)
                    }
                }
                load.entries = Self.oldestFirst(entries)
            } catch {
                // A directory that cannot be listed may hold every month; a
                // caller that took it for empty would write over them.
                load.unreadable.append(entriesDirectory)
            }
        }

        if fileManager.fileExists(atPath: topicsURL.path) {
            do {
                load.topics = try decoder.decode([MemoryTopic].self, from: Data(contentsOf: topicsURL))
            } catch {
                load.unreadable.append(topicsURL)
            }
        }

        return load
    }

    /// The stamp the last finished pages rebuild wrote, trimmed; nil when it
    /// is absent, unreadable or blank, all of which call for a rebuild.
    public func pagesFormat() -> String? {
        guard let text = try? String(contentsOf: pagesFormatURL, encoding: .utf8) else { return nil }
        let stamp = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return stamp.isEmpty ? nil : stamp
    }

    /// Writes every file owner-only (0600) and atomically, with every directory
    /// 0700. Removing a file that is already absent succeeds. The sweep and then
    /// the stamp come last, so a throw anywhere leaves the stamp unwritten.
    public func apply(_ write: MemoryWrite) throws {
        let encoder = Self.makeEncoder()

        for (month, entries) in write.months.sorted(by: { $0.key < $1.key }) {
            let url = monthURL(month)
            if entries.isEmpty {
                try removeVoiceourPrivateState(at: url)
            } else {
                try writeVoiceourPrivateState(encoder.encode(entries), to: url)
            }
        }

        if let topics = write.topics {
            if topics.isEmpty {
                try removeVoiceourPrivateState(at: topicsURL)
            } else {
                try writeVoiceourPrivateState(encoder.encode(topics), to: topicsURL)
            }
        }

        for page in write.pages {
            try writeVoiceourPrivateState(Data(page.text.utf8), to: root.appendingPathComponent(page.path))
        }

        for path in write.removedPages {
            try removeVoiceourPrivateState(at: root.appendingPathComponent(path))
        }

        if write.sweepDerived {
            try sweepDerivedPages(keeping: Set(write.pages.map(\.path)))
        }

        // The page directories are created with intermediates, which leaves the
        // root itself at the default mode until it is tightened here.
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        }

        if let stamp = write.pagesFormat {
            try writeVoiceourPrivateState(Data("\(stamp)\n".utf8), to: pagesFormatURL)
        }
    }

    /// Removes every regular `*.md` file directly inside a derived page folder
    /// that `kept` does not name. A symlink, a subfolder or a set-aside
    /// `*.corrupt-*` file is never touched, and neither is a folder that is
    /// itself a symlink: the sweep never reaches outside the pages it owns.
    private func sweepDerivedPages(keeping kept: Set<String>) throws {
        let fileManager = FileManager.default
        for folder in Self.derivedPageFolders {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            guard fileManager.fileExists(atPath: directory.path),
                try Self.fileType(at: directory) == .typeDirectory
            else { continue }
            for name in try fileManager.contentsOfDirectory(atPath: directory.path) {
                guard name.hasSuffix(".md"), !name.contains(".corrupt-"), !kept.contains("\(folder)/\(name)") else {
                    continue
                }
                let url = directory.appendingPathComponent(name)
                if try Self.fileType(at: url) == .typeRegular {
                    try removeVoiceourPrivateState(at: url)
                }
            }
        }
    }

    /// The item's own type: a symlink reads as a symlink, never as its target.
    private static func fileType(at url: URL) throws -> FileAttributeType? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
    }

    /// Removes the whole root, `agents/` included; an absent root is success.
    public func clear() throws {
        try removeVoiceourPrivateState(at: root)
    }

    /// Stable oldest-first order: entries made in the same instant keep the
    /// order they were read in.
    static func oldestFirst(_ entries: [MemoryEntry]) -> [MemoryEntry] {
        entries.enumerated().sorted { lhs, rhs in
            if lhs.element.createdAt != rhs.element.createdAt {
                return lhs.element.createdAt < rhs.element.createdAt
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// ISO 8601 dates and sorted, pretty-printed keys keep the source records
    /// readable by an agent and byte-stable across rewrites of the same state.
    /// Slashes stay unescaped so a working directory reads as the path it is.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
