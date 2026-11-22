import Foundation
import Testing

@testable import VoiceourBench

// `fixtures/text/qwen3-tokenizer.json` holds texts and the ids the reference tokenizer gives them, with the
// subset of the GGUF's pieces (id, piece, token type) and ranked merges those texts reach. Each case's `ids` come
// from the Hugging Face `tokenizers` library over spokenly/cleanup-1's `tokenizer.json`, with
// `encode_special_tokens` so control tokens are text, as llama.cpp's `parse_special = false` treats them; the
// tables come from `cleanup-1-q8_0.gguf`. To add a case, append `{"text": …, "ids": []}` to `cases` and
// regenerate from the repository root (the texts are read back from the fixture):
//
//   uv run --no-config --python 3.12 --with tokenizers==0.22.1 --with gguf==0.19.0 python - \
//     <cleanup-1>/tokenizer.json <cleanup-1-gguf>/cleanup-1-q8_0.gguf fixtures/text/qwen3-tokenizer.json <<'EOF'
//   import json, sys
//   import gguf
//   from tokenizers import Tokenizer
//
//   hf = Tokenizer.from_file(sys.argv[1])
//   hf.encode_special_tokens = True  # control tokens are text, as llama.cpp's parse_special = false
//   reader = gguf.GGUFReader(sys.argv[2])
//   field = lambda key: reader.fields[key]
//   strings = lambda f: [bytes(f.parts[i]).decode("utf-8") for i in f.data]
//   pieces = strings(field("tokenizer.ggml.tokens"))
//   types = [int(field("tokenizer.ggml.token_type").parts[i][0]) for i in field("tokenizer.ggml.token_type").data]
//   merges = strings(field("tokenizer.ggml.merges"))
//   assert merges == [" ".join(m) for m in json.load(open(sys.argv[1]))["model"]["merges"]]
//   texts = [c["text"] for c in json.load(open(sys.argv[3]))["cases"]]
//   cases = [{"text": t, "ids": hf.encode(t, add_special_tokens=False).ids} for t in texts]
//   words = [w for t in texts for w, _ in hf.pre_tokenizer.pre_tokenize_str(hf.normalizer.normalize_str(t))]
//   substrings = {w[i:j] for w in words for i in range(len(w)) for j in range(i + 1, len(w) + 1)}
//   ids = {p: i for i, p in reversed(list(enumerate(pieces)))}
//   keep = {ids[s] for s in substrings if s in ids} | {i for i, t in enumerate(types) if t in (3, 4)}
//   keep |= {i for c in cases for i in c["ids"]}
//   kept_merges = [[r, m] for r, m in enumerate(merges) if m.replace(" ", "", 1) in substrings]
//   keep |= {ids[p] for _, m in kept_merges for p in m.split(" ", 1)}
//   printable = [*range(0x21, 0x7F), *range(0xA1, 0xAD), *range(0xAE, 0x100)]
//   keep |= {ids[chr(b)] for b in printable} | {ids[chr(256 + n)] for n in range(256 - len(printable))}
//   lines = lambda xs, ascii=False: ",\n".join(json.dumps(x, ensure_ascii=ascii) for x in xs)
//   source = "spokenly/cleanup-1 tokenizer.json (tokenizers 0.22.1, encode_special_tokens) and cleanup-1-q8_0.gguf tables"
//   open(sys.argv[3], "w").write(
//       f'{{"source": {json.dumps(source)},\n"tokens": [\n{lines([[i, pieces[i], types[i]] for i in sorted(keep)])}\n],\n'
//       f'"merges": [\n{lines(kept_merges)}\n],\n"cases": [\n{lines(cases, ascii=True)}\n]}}\n')
//   EOF
//
// Every merge whose concatenation occurs inside a pre-token is kept, so the subset holds each merge the full
// table would apply, at its full-table rank, and the encoder reaches the same ids.

@Suite("Qwen3 tokenizer")
struct Qwen3TokenizerTests {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            var text: String
            var ids: [Int32]
        }

        var tokens: [[TokenField]]
        var merges: [[TokenField]]
        var cases: [Case]
    }

    /// A fixture array element: an id, a piece or a type.
    private enum TokenField: Decodable {
        case number(Int)
        case text(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) {
                self = .number(number)
            } else {
                self = .text(try container.decode(String.self))
            }
        }

        var number: Int? {
            if case .number(let value) = self { return value }
            return nil
        }

        var text: String? {
            if case .text(let value) = self { return value }
            return nil
        }
    }

    private static func load() throws -> (tokenizer: Qwen3Tokenizer, cases: [Fixture.Case]) {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/text/qwen3-tokenizer.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let tokens = try fixture.tokens.map { fields in
            let id = try #require(fields[0].number.flatMap { Int32(exactly: $0) })
            let piece = try #require(fields[1].text)
            let kind = try #require(fields[2].number.flatMap { Int32(exactly: $0) }.flatMap(Qwen3Tokenizer.Kind.init))
            return Qwen3Tokenizer.Token(id: id, piece: piece, kind: kind)
        }
        let merges = try fixture.merges.map { fields in
            Qwen3Tokenizer.Merge(rank: try #require(fields[0].number), text: try #require(fields[1].text))
        }
        return (try Qwen3Tokenizer(tokens: tokens, merges: merges), fixture.cases)
    }

    /// The fixture's tokenizer, for suites that need real Qwen3 pieces without a model.
    static func fixtureTokenizer() throws -> Qwen3Tokenizer {
        try load().tokenizer
    }

    @Test func encodesEveryFixtureTextAsTheReferenceTokenizer() throws {
        let (tokenizer, cases) = try Self.load()
        #expect(cases.count >= 20)
        for fixtureCase in cases {
            #expect(tokenizer.encode(fixtureCase.text) == fixtureCase.ids, "\(String(reflecting: fixtureCase.text))")
        }
    }

    @Test func decodesEveryFixtureEncodingBackToItsNormalizedText() throws {
        let (tokenizer, cases) = try Self.load()
        for fixtureCase in cases {
            let expected = fixtureCase.text.precomposedStringWithCanonicalMapping
            #expect(
                Array(tokenizer.decodeBytes(fixtureCase.ids)) == Array(expected.utf8), "\(String(reflecting: expected))"
            )
            #expect(tokenizer.decode(tokenizer.encode(fixtureCase.text)) == expected)
        }
    }

    @Test func controlTokensDecodeToNothingAndUserTokensAsWritten() throws {
        let (tokenizer, _) = try Self.load()
        // 151643 <|endoftext|> and 151645 <|im_end|> are control tokens, 151667 <think> is user-defined.
        #expect(tokenizer.decodeBytes([151643, 151645]).isEmpty)
        #expect(tokenizer.decode([151667, 151643]) == "<think>")
    }

    @Test(arguments: [
        ("a  b", ["a", " ", " b"]),
        ("x\n\n  y", ["x", "\n\n", " ", " y"]),
        ("it's 12 ok?!\n", ["it", "'s", " ", "1", "2", " ok", "?!\n"]),
        ("end  ", ["end", "  "]),
    ])
    func preTokenizerSplitsAsTheQwen2Regex(text: String, words: [String]) {
        let scalars = Array(text.unicodeScalars)
        let split = Qwen3Tokenizer.preTokenize(scalars).map { range in
            String(String.UnicodeScalarView(scalars[range]))
        }
        #expect(split == words)
    }
}

@Suite("Polish command")
struct PolishCommandTests {
    @Test func defaultsToNgramDraftingTwoTwentyFour() throws {
        let command = try PolishCommand.parse([
            "--input", "/tmp/cases.jsonl", "--output", "/tmp/out", "--model", "/tmp/model.gguf",
        ])
        #expect(command.ngram?.n == 2)
        #expect(command.ngram?.m == 24)
        #expect(command.reps == 3)
        #expect(command.maxNewTokens == 512)
    }

    @Test func noNgramDisablesDraftingAndExcludesNgramSizes() throws {
        let plain = try PolishCommand.parse([
            "--input", "/tmp/cases.jsonl", "--output", "/tmp/out", "--model", "/tmp/model.gguf", "--no-ngram",
        ])
        #expect(plain.ngram == nil)
        #expect(throws: BenchError.self) {
            try PolishCommand.parse([
                "--input", "/tmp/c.jsonl", "--output", "/tmp/o", "--model", "/tmp/m.gguf", "--no-ngram", "--ngram-n",
                "3",
            ])
        }
    }

    @Test func trimsOnlyTheHarnessWhitespace() {
        #expect(Array(PolishCommand.trimmed(Array(" \t\n\u{0B}\u{0C}\r Done.\n ".utf8))) == Array("Done.".utf8))
        #expect(Array(PolishCommand.trimmed(Array("\u{00A0}x\u{00A0}".utf8))) == Array("\u{00A0}x\u{00A0}".utf8))
        #expect(PolishCommand.trimmed(Array("  \n".utf8)).isEmpty)
    }

    @Test func statisticsMatchThePolishLabDefinitions() {
        #expect(PolishStatistics.median([3, 1, 2]) == 2)
        #expect(PolishStatistics.median([4, 1, 3, 2]) == 2.5)
        // round(0.95 * 35) = round(33.25) = 33; round(0.95 * 9) = round(8.55) = 9, the last index.
        #expect(PolishStatistics.percentile((0..<36).map(Double.init), 0.95) == 33)
        #expect(PolishStatistics.percentile((0..<10).map(Double.init), 0.95) == 9)
        // round(0.5 * 5) = round(2.5) = 2, half to even.
        #expect(PolishStatistics.percentile((0..<6).map(Double.init), 0.5) == 2)
    }
}
