import Foundation
import VoiceCore

/// Finds, for each dictation, the one local agent session whose own prompt
/// log holds its whole text, so a dictation delivered before binding could
/// see it can still be linked, by its words and never by likeness.
///
/// - omp: the user messages of each session file directly in a project folder
///   under `~/.omp/agent/sessions`, sent no earlier than a second before the
///   file's own `session` record. A fork or a seance copies earlier prompts
///   with their original times into a file that began later, so only the
///   session the words were sent to keeps them. A file whose head names no
///   start is skipped. Subagent folders, `sessions-archive` and
///   `custom-session-files` are never reached.
/// - Claude Code: `~/.claude/history.jsonl` lines that name a session, pasted
///   text expanded only where Claude Code kept it.
///
/// Only files modified since the earliest window opened are read, each
/// streamed once with no size cap; only prompts inside some query's window are
/// kept, and every query is then matched against those. Only canonical paths
/// under `~/.omp/agent` and `~/.claude` are opened. The prompts live only for
/// the call and are never logged. A cancelled task stops between files and
/// finds nothing.
public struct AgentPromptEvidenceReader: AgentPromptEvidenceReading {
    private let files: AgentSessionFiles

    public init(homeDirectory: URL) {
        self.init(files: AgentSessionFiles(home: homeDirectory, fileSystem: .live))
    }

    init(files: AgentSessionFiles) {
        self.files = files
    }

    public func evidence(for queries: [PromptEvidenceQuery]) -> PromptEvidenceRun {
        let wanted = queries.compactMap { Wanted($0) }
        guard let windows = Windows(wanted.map(\.window)) else { return PromptEvidenceRun() }
        var prompts: [Prompt] = []
        readOmp(within: windows, into: &prompts)
        readClaudeCode(within: windows, into: &prompts)
        guard !Task.isCancelled else { return PromptEvidenceRun() }
        return match(wanted, in: prompts.sorted { $0.sentAt < $1.sentAt })
    }

    // MARK: Reading

    private func readOmp(within windows: Windows, into prompts: inout [Prompt]) {
        for file in files.ompTopLevelSessionFiles() {
            guard !Task.isCancelled else { return }
            guard let size = sizeIfModified(file.path, since: windows.opens) else { continue }
            let head = files.ompHead(file.path)
            guard let startedAt = head.startedAt else { continue }
            let earliest = startedAt.addingTimeInterval(-PromptEvidence.leadTime)
            let session = AgentSessionKey(agent: .omp, sessionId: file.sessionId)
            let source = Source.omp(path: file.path, title: head.title, workingDirectory: head.workingDirectory)
            let needle = AgentSessionFileReader.ompUserNeedle
            files.forEachLine(in: file.path, from: 0, to: size, containing: needle) { line in
                guard
                    let prompt = AgentSessionFileReader.ompPrompt(line),
                    prompt.sentAt >= earliest,
                    windows.contains(prompt.sentAt)
                else { return }
                prompts.append(
                    Prompt(
                        session: session,
                        sentAt: prompt.sentAt,
                        text: PromptEvidence.collapsed(prompt.text),
                        source: source
                    )
                )
            }
        }
    }

    private func readClaudeCode(within windows: Windows, into prompts: inout [Prompt]) {
        guard
            !Task.isCancelled,
            case .inside(let history) = files.location(of: files.path(.claude, "history.jsonl"), under: .claude),
            let size = sizeIfModified(history, since: windows.opens)
        else { return }
        let needle = AgentSessionFileReader.claudeCodeSessionNeedle
        files.forEachLine(in: history, from: 0, to: size, containing: needle) { line in
            guard
                let record = AgentSessionFileReader.claudeCodeHistoryPrompt(line),
                AgentSessionFiles.isSessionId(record.sessionId),
                windows.contains(record.prompt.sentAt)
            else { return }
            let project = (try? JSONDecoder().decode(ClaudeProjectRecord.self, from: line))?.project
            prompts.append(
                Prompt(
                    session: AgentSessionKey(agent: .claudeCode, sessionId: record.sessionId),
                    sentAt: record.prompt.sentAt,
                    text: PromptEvidence.collapsed(record.prompt.text),
                    source: .claudeCode(project: project.flatMap(AgentSessionFiles.nonBlank))
                )
            )
        }
    }

    /// The size of the file at `path` when it changed at or after `date`; nil
    /// when it is older, so it cannot hold a prompt any query could claim.
    private func sizeIfModified(_ path: String, since date: Date) -> Int? {
        guard let modified = files.fileSystem.modificationDate(path), modified >= date else { return nil }
        return files.fileSystem.fileSize(path)
    }

    // MARK: Matching

    /// `prompts` must be oldest first.
    private func match(_ wanted: [Wanted], in prompts: [Prompt]) -> PromptEvidenceRun {
        var run = PromptEvidenceRun()
        var claudeCodeFacts: [String: (sessionFile: String?, title: String?)] = [:]
        for query in wanted {
            // Each session's earliest prompt in the window that holds the words.
            var holders: [AgentSessionKey: Prompt] = [:]
            var position = firstIndex(in: prompts, notBefore: query.window.lowerBound)
            while position < prompts.count, prompts[position].sentAt <= query.window.upperBound {
                let prompt = prompts[position]
                if holders[prompt.session] == nil, prompt.text.contains(query.text) {
                    holders[prompt.session] = prompt
                }
                position += 1
            }
            guard holders.count == 1, let prompt = holders.values.first else {
                if holders.count > 1 {
                    run.ambiguous.insert(query.id)
                }
                continue
            }
            switch prompt.source {
            case .omp(let path, let title, let workingDirectory):
                run.matches[query.id] = PromptEvidenceMatch(
                    agent: .omp,
                    sessionId: prompt.session.sessionId,
                    sentAt: prompt.sentAt,
                    sessionFile: path,
                    workingDirectory: workingDirectory,
                    title: title
                )
            case .claudeCode(let project):
                let sessionId = prompt.session.sessionId
                let facts = claudeCodeFacts[sessionId] ?? claudeCodeSessionFacts(sessionId)
                claudeCodeFacts[sessionId] = facts
                run.matches[query.id] = PromptEvidenceMatch(
                    agent: .claudeCode,
                    sessionId: sessionId,
                    sentAt: prompt.sentAt,
                    sessionFile: facts.sessionFile,
                    workingDirectory: project,
                    title: facts.title
                )
            }
        }
        return run
    }

    /// The transcript and title of a Claude Code session, as a binding reads
    /// them: the registry name unless derived, else the transcript's title.
    private func claudeCodeSessionFacts(_ sessionId: String) -> (sessionFile: String?, title: String?) {
        let transcript = files.claudeTranscript(sessionId: sessionId)
        let title = files.claudeRegistryName(sessionId: sessionId) ?? transcript.flatMap(files.claudeTranscriptTitle)
        return (transcript, title)
    }

    /// The index of the first prompt sent at or after `date`.
    private func firstIndex(in prompts: [Prompt], notBefore date: Date) -> Int {
        var low = 0
        var high = prompts.count
        while low < high {
            let middle = (low + high) / 2
            if prompts[middle].sentAt < date {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    // MARK: Types

    /// A query long enough to count, its text collapsed.
    private struct Wanted {
        var id: UUID
        var text: String
        var window: ClosedRange<Date>

        init?(_ query: PromptEvidenceQuery) {
            guard PromptEvidence.words(query.text) >= PromptEvidence.minimumWords else { return nil }
            id = query.id
            text = PromptEvidence.collapsed(query.text)
            window = PromptEvidence.window(around: query.at)
        }
    }

    /// A prompt some query's window holds, its text collapsed.
    private struct Prompt {
        var session: AgentSessionKey
        var sentAt: Date
        var text: String
        var source: Source
    }

    /// Where a prompt was read, with the session facts that place gives.
    private enum Source {
        case omp(path: String, title: String?, workingDirectory: String?)
        case claudeCode(project: String?)
    }

    /// The union of the queries' windows, so one pass keeps every prompt any
    /// query could claim and no other.
    private struct Windows {
        /// Disjoint and in order.
        private let spans: [ClosedRange<Date>]

        init?(_ windows: [ClosedRange<Date>]) {
            var spans: [ClosedRange<Date>] = []
            for window in windows.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let last = spans.last, window.lowerBound <= last.upperBound {
                    spans[spans.count - 1] = last.lowerBound...max(last.upperBound, window.upperBound)
                } else {
                    spans.append(window)
                }
            }
            guard !spans.isEmpty else { return nil }
            self.spans = spans
        }

        /// When the earliest window opens.
        var opens: Date { spans[0].lowerBound }

        func contains(_ date: Date) -> Bool {
            // The number of spans opening at or before `date`.
            var low = 0
            var high = spans.count
            while low < high {
                let middle = (low + high) / 2
                if spans[middle].lowerBound <= date {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return low > 0 && spans[low - 1].upperBound >= date
        }
    }

    /// A `history.jsonl` line's working directory, decoded only once its
    /// prompt falls inside a window.
    private struct ClaudeProjectRecord: Decodable {
        var project: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            project = try? container.decodeIfPresent(String.self, forKey: .project)
        }

        private enum CodingKeys: String, CodingKey {
            case project
        }
    }
}
