# Benchmark data licences

Voiceour's source code, including the benchmark tooling under `bench/`, is licensed under
the MIT License in `LICENSE`. That licence does not cover every byte committed under
`benchmarks/results/`.

Six of the committed reports embed verbatim reference transcripts and utterance identifiers
from two third-party speech corpora. Both corpora are licensed under the Creative Commons
Attribution 4.0 International licence (CC BY 4.0) by their own creators, not by Voiceour.
This file is the attribution CC BY 4.0 section 3(a) requires, and reuse of that corpus text
is governed by CC BY 4.0 rather than by Voiceour's MIT licence.

CC BY 4.0 carries no ShareAlike term, so the surrounding report structure, metrics, row
identities Voiceour assigns, and the tooling that writes them all remain MIT.

## Where the corpus text is

| report under `benchmarks/results/` | corpus | keys holding corpus text |
| --- | --- | --- |
| `20260815T143055Z-librispeech-parakeet-stt.json` | LibriSpeech | `worst_10[].reference`, `worst_10[].id`, `successful_row_ids[]` |
| `20260815T172106Z-librispeech-parakeet-stt.json` | LibriSpeech | `worst_10[].reference`, `worst_10[].id`, `successful_row_ids[]` |
| `20260815T172225Z-librispeech-apple-stt.json` | LibriSpeech | `worst_10[].reference`, `worst_10[].id` |
| `20260815T143116Z-fleurs-parakeet-stt.json` | FLEURS | `worst_10[].reference`, `worst_10[].id`, `successful_row_ids[]` |
| `20260815T172117Z-fleurs-parakeet-stt.json` | FLEURS | `worst_10[].reference`, `worst_10[].id`, `successful_row_ids[]` |
| `20260815T172240Z-fleurs-apple-stt.json` | FLEURS | `worst_10[].reference`, `worst_10[].id` |

`worst_10[].reference` is one whole reference transcript per row, reproduced byte for byte
from the corpus. `worst_10[].id` and `successful_row_ids[]` are Voiceour row identifiers that
embed the corpus split and the corpus row ordinal. The two `-apple-stt` reports predate
row-id recording, so they carry corpus text only in `worst_10`.

The sibling `worst_10[].raw_transcript` and `worst_10[].final_text` on those rows are machine
transcriptions Voiceour produced from the corpus recordings. They are outputs of this
repository's pipeline over CC BY 4.0 source material, and they are only meaningful next to
the reference they are scored against.

Nothing else in a report is corpus material. `anchors` holds two published word-error-rate
figures, `metrics` holds computed numbers, and `error_row_ids[]` is empty wherever it appears.

## LibriSpeech

- **Creators** — Vassil Panayotov, Guoguo Chen, Daniel Povey, Sanjeev Khudanpur.
- **Title** — *LibriSpeech: an ASR corpus based on public domain audio books*, ICASSP 2015.
  The transcripts above come from the `test.clean` and `test.other` splits.
- **Source** — https://www.openslr.org/12/
- **Licence** — Creative Commons Attribution 4.0 International (CC BY 4.0),
  https://creativecommons.org/licenses/by/4.0/legalcode.en
- **Disclaimer** — the licensor offers the corpus as-is, gives no representations or
  warranties about it, and limits liability. Sections 5 and 6 of the licence above state the
  disclaimer of warranties and limitation of liability that apply.
- **No endorsement** — none of the creators named above endorse, sponsor or certify Voiceour
  or its measurements.
- **Previous modifications** — Voiceour reads these transcripts through the
  `hf-audio/open-asr-leaderboard` mirror, configuration `librispeech`, which supplies them
  case-folded to lower case and without punctuation. The corpus's own release at the source
  URI above is upper-case. That mirror publishes no licence of its own; the corpus licence
  above is the one that governs.
- **Changes** — Voiceour extracted whole reference transcripts for the ten worst-scoring rows
  of a run, plus the identifiers of the rows it scored, into the JSON reports listed above.
  The transcript strings are reproduced verbatim; Voiceour alters no transcript and
  redistributes neither the audio nor the full transcript set.

## FLEURS

- **Creators** — Alexis Conneau, Min Ma, Simran Khanuja, Yu Zhang, Vera Axelrod, Siddharth
  Dalmia, Jason Riesa, Clara Rivera, Ankur Bapna (Google).
- **Title** — *FLEURS: Few-shot Learning Evaluation of Universal Representations of Speech*,
  arXiv:2205.12446. The transcripts above come from the `en_us` `test` split.
- **Source** — https://huggingface.co/datasets/google/fleurs
- **Licence** — Creative Commons Attribution 4.0 International (CC BY 4.0),
  https://creativecommons.org/licenses/by/4.0/legalcode.en
- **Disclaimer** — the licensor offers the corpus as-is, gives no representations or
  warranties about it, and limits liability. Sections 5 and 6 of the licence above state the
  disclaimer of warranties and limitation of liability that apply.
- **No endorsement** — neither Google nor the creators named above endorse, sponsor or
  certify Voiceour or its measurements.
- **Previous modifications** — the corpus itself publishes two transcript forms per
  utterance, a normalized `transcription` and a cased, punctuated `raw_transcription`. The
  committed reports carry the normalized `transcription` as the corpus supplies it. No
  intermediate publisher stands between the source URI above and this repository.
- **Changes** — as for LibriSpeech: whole reference transcripts for the ten worst-scoring
  rows of a run and the identifiers of the rows scored, reproduced verbatim into the JSON
  reports listed above.

## Reports with no third-party corpus text

`20260815T203246Z-techterms-parakeet-stt.json` is entirely Voiceour's own material. Its
sixteen `techterms_*` sentences are declared as `TECHTERMS_CASES` in
`bench/src/voiceour_bench/datasets_prep.py` and spoken by the local macOS `say` voice, so
that report is MIT with the rest of the repository. The `smoke` tier is the same kind of
locally synthesized fixture and its reports are never committed.

## What is not committed

`benchmarks/data/` is gitignored working space that `bench` regenerates on demand: corpus
audio, the manifests, the full reference sets, and the Hugging Face download cache all live
there and none of it is tracked. Per-utterance `.results.jsonl` files are ignored too.
Acquiring either corpus is the reader's own act, under that corpus's licence and directly
from the source URI above.

## LibriSpeech language-model resources

The separate LibriSpeech language-model release at https://www.openslr.org/11/ — the n-gram
models, the lexicon, and the vocabulary lists — is public domain, not CC BY 4.0. No file from
it is present in this repository. Anything taken from it in future belongs under that
public-domain status and must not be filed under the CC BY 4.0 attribution above.
