import Foundation
import Testing

@testable import VoiceCore

/// Topic ids name files and label choices, so the slug rules and every refusal
/// are what keeps two topics from ever sharing an id.
@Suite("TopicCatalog")
struct TopicCatalogTests {
    private let created = Date(timeIntervalSince1970: 1_700_000_000)
    private let later = Date(timeIntervalSince1970: 1_700_086_400)

    private func topic(_ id: String, _ name: String, summary: String = "") -> MemoryTopic {
        MemoryTopic(id: id, name: name, summary: summary, createdAt: created)
    }

    // MARK: Slugs

    @Test func aSlugLowersAndJoinsWordsWithOneDash() {
        #expect(TopicCatalog.slug(for: "Memory System") == "memory-system")
    }

    @Test func aRunOfSymbolsBecomesOneDashAndTheEndsAreTrimmed() {
        #expect(TopicCatalog.slug(for: "  C++ & Rust!  ") == "c-rust")
    }

    @Test func diacriticsFoldToTheirBaseLetter() {
        #expect(TopicCatalog.slug(for: "Café notes") == "cafe-notes")
    }

    @Test func aNameWithNoLetterOrDigitHasAnEmptySlug() {
        #expect(TopicCatalog.slug(for: "---") == "")
        #expect(TopicCatalog.slug(for: "   ") == "")
    }

    // MARK: Adding

    @Test func addingTrimsTheNameFoldsTheSummaryAndAppends() throws {
        let existing = [topic("rust", "Rust")]
        let result = try TopicCatalog.adding(
            name: "  Memory System \n", summary: "  Design of the\npersistent store.\n", to: existing,
            now: later)
        #expect(
            result == [
                topic("rust", "Rust"),
                MemoryTopic(
                    id: "memory-system", name: "Memory System", summary: "Design of the persistent store.",
                    createdAt: later),
            ])
    }

    @Test func addingANameWithoutLettersOrDigitsIsRefused() {
        #expect(throws: TopicCatalog.Refusal.emptyName) {
            try TopicCatalog.adding(name: " --- ", summary: "", to: [], now: later)
        }
    }

    @Test func aNameWhoseSlugIsNoneIsReserved() {
        #expect(throws: TopicCatalog.Refusal.reserved) {
            try TopicCatalog.adding(name: "None", summary: "", to: [], now: later)
        }
        #expect(throws: TopicCatalog.Refusal.reserved) {
            try TopicCatalog.adding(name: " -none- ", summary: "", to: [], now: later)
        }
    }

    @Test func aDuplicateIsRefusedByCaseInsensitiveName() {
        let existing = [topic("ideas", "Ideas")]
        #expect(throws: TopicCatalog.Refusal.duplicate("Ideas")) {
            try TopicCatalog.adding(name: "IDEAS", summary: "", to: existing, now: later)
        }
    }

    @Test func aDuplicateIsRefusedBySlug() {
        let existing = [topic("memory-system", "memory system")]
        #expect(throws: TopicCatalog.Refusal.duplicate("memory system")) {
            try TopicCatalog.adding(name: "Memory-System", summary: "", to: existing, now: later)
        }
    }

    /// After a rename the id and the name's slug differ; the old id still
    /// belongs to its topic and a new name must not claim it.
    @Test func aDuplicateIsRefusedByAnExistingIdAfterARename() {
        let existing = [topic("memory-system", "Persistence")]
        #expect(throws: TopicCatalog.Refusal.duplicate("Persistence")) {
            try TopicCatalog.adding(name: "Memory System", summary: "", to: existing, now: later)
        }
    }

    @Test func theTopicAfterTheMaximumIsRefused() throws {
        let full = (1...OrganizerPolicy.maximumTopics).map { topic("topic-\($0)", "Topic \($0)") }
        #expect(full.count == 254)
        #expect(throws: TopicCatalog.Refusal.tooMany) {
            try TopicCatalog.adding(name: "One more", summary: "", to: full, now: later)
        }
        let roomForOne = Array(full.dropLast())
        let result = try TopicCatalog.adding(name: "One more", summary: "", to: roomForOne, now: later)
        #expect(result.count == 254)
        #expect(result.last?.id == "one-more")
    }

    // MARK: Updating

    @Test func updatingKeepsTheIdAndCreationDate() throws {
        let existing = [topic("memory-system", "Memory System", summary: "Old."), topic("rust", "Rust")]
        let result = try TopicCatalog.updating(
            id: "memory-system", name: "  Persistence ", summary: "Where\nentries live.", in: existing)
        #expect(
            result == [
                MemoryTopic(
                    id: "memory-system", name: "Persistence", summary: "Where entries live.",
                    createdAt: created),
                topic("rust", "Rust"),
            ])
    }

    @Test func updatingMayKeepItsOwnNameOrChangeItsCase() throws {
        let existing = [topic("memory-system", "Memory System")]
        let same = try TopicCatalog.updating(
            id: "memory-system", name: "Memory System", summary: "New.", in: existing)
        #expect(same == [topic("memory-system", "Memory System", summary: "New.")])
        let recased = try TopicCatalog.updating(
            id: "memory-system", name: "memory system", summary: "", in: existing)
        #expect(recased == [topic("memory-system", "memory system")])
    }

    @Test func updatingRefusesACollisionWithAnotherTopic() {
        let existing = [topic("memory-system", "Memory System"), topic("rust", "Rust")]
        #expect(throws: TopicCatalog.Refusal.duplicate("Rust")) {
            try TopicCatalog.updating(id: "memory-system", name: "RUST", summary: "", in: existing)
        }
    }

    @Test func updatingAppliesTheEmptyAndReservedRules() {
        let existing = [topic("memory-system", "Memory System")]
        #expect(throws: TopicCatalog.Refusal.emptyName) {
            try TopicCatalog.updating(id: "memory-system", name: "!!", summary: "", in: existing)
        }
        #expect(throws: TopicCatalog.Refusal.reserved) {
            try TopicCatalog.updating(id: "memory-system", name: "none", summary: "", in: existing)
        }
    }

    @Test func updatingAnUnknownIdReturnsTheListUnchanged() throws {
        let existing = [topic("memory-system", "Memory System")]
        let result = try TopicCatalog.updating(id: "missing", name: "", summary: "", in: existing)
        #expect(result == existing)
    }

    // MARK: Removing

    @Test func removingDropsOnlyThatTopic() {
        let existing = [topic("a", "A"), topic("b", "B"), topic("c", "C")]
        #expect(TopicCatalog.removing(id: "b", from: existing) == [topic("a", "A"), topic("c", "C")])
        #expect(TopicCatalog.removing(id: "missing", from: existing) == existing)
    }
}
