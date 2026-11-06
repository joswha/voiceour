# Granite CTC word spotting — wave 2 result, 2026-11-06

Preregistration `research/prereg/granite-ctc-word-spotting-wave2.md`, frozen at `55e4b3a` on code
`e337e1d` (the spotter, both rendering rules, heard-as variants). The run used a release build of `55e4b3a`,
whose commits after `e337e1d` touch only research files. Data from
`research/prereg/tools/granite_ctc_spotting_wave2_data.py`, analysis
`granite_ctc_spotting_wave2_analysis.py`. One Apple M4 Pro, production `GraniteContext` (Metal, 6 threads,
mapped weights), Granite `vladers/granite-speech-5.0-470m-turboctc-GGUF` @ `bd7db273` Q8_0. The machine
updated from macOS 27.0.1 to 27.3 (26C5035r) during the run; the real-speech taught arm ran after the update,
and its greedy text equals the plain arm's, run before it, on all 6,583 rows.

## Verdict: PASS

| measure | value |
| --- | ---: |
| positives (141 targets × 2 sentences, voices Daniel, Karen, Moira, Rishi) | 282 |
| baseline hits `H0` (greedy + the app's text stage) | 184 |
| misses | 98 |
| hits at the frozen point `(6, 1.5, 1)`, `H1` | 213 |
| gain `G` | +29 |
| PASS gain bar, `max(10, ⌈0.25·98⌉)` | 25 |
| KILL gain bar, `max(5, ⌈0.10·98⌉)` | 10 |
| lost hits `L` | 0 |
| false activations `F`, over all 7,008 rows | 0 |
| damaged rows `D` | 0 |
| rows whose text changed | 29, each a positive gaining its term |

Every bar holds, so by the frozen rule the spotter may be productized at this operating point and nowhere
else.

## Deviations from the preregistration

- **Real speech without TED-LIUM.** On 2026-11-06 `hf-audio/open-asr-leaderboard` no longer holds `tedlium`
  data files: its `test` split resolves to zero rows against 1,155 declared. The real-speech set is therefore
  the `voxpopuli` (1,842) and `earnings22` (2,741) test splits in full and the first 2,000 `gigaspeech` rows:
  6,583 rows instead of about 7,738. The change was committed (`cbd8c70`) before any wave 2 output existed. `F`
  and `D` are bounded on these three corpora only.
- **Synthesis retries.** One `say` call stalled for twenty minutes. The data script now bounds each call and
  retries it, keeping files a run already completed; text, voice and conversion are unchanged.
- **Restarts.** The machine rebooted for the OS update while the real-speech taught arm ran, and a relaunched
  copy briefly wrote the same file. Both runs were stopped and the arm rerun alone; every reported file is
  one complete run whose row count matches its manifest.

## Exploratory findings, not gating

- **Every voice gains.** Daniel 52 → 58 of 71, Karen 50 → 57 of 71, Moira 41 → 50 of 70, Rishi 41 → 48 of 70.
- **The looser point** `(8, 1.5, 1)`, wave 1's full-data best: +30, with `L`, `F` and `D` all 0.
- **Gained terms:** Argon2, Burp Suite (2), CMake (2), CUDA, Databricks, Fail2ban (2), Gradle, HMAC (2),
  Hashcat, HorizontalPodAutoscaler, Kotlin, Metasploit, NSPasteboard, OAuth 2.0, PostgreSQL, Redis,
  URLSession (2), Wireshark, containerd, iptables, nginx, nmap, scikit-learn, viewDidLoad.
- **Reach.** 69 misses remain, and 48 of them have no candidate for their term at all: as in wave 1, the
  audio never comes near the spelling under Granite's posteriors.
- **Real speech.** 15 candidates over 6,583 rows, and none changed a row. Twelve are the target
  `Instruments` over the word *instruments* (VoxPopuli) at score 0, the greedy path itself. They change
  nothing because the baseline already wrote the term there: the ordinary-word list holds *instrument* but
  not *instruments*, so `Glossary.canonicalize` recases the term's own surface (`musical instruments` →
  `musical Instruments`) before spotting is consulted. The others are `Deno` and `VPC` (unrenderable) and
  `CVE` over *Cade.* at −2.66 nats per token. The 120 hard negatives produced no candidate.
- **A blind spot in `F` and `D`.** `F` looks for an unsupported term in the casefolded reference and `D` uses
  uncased U-WER, so neither can see a rewrite that only recases a word. Spotting a target over the same
  letters behaves exactly like the text stage's own-surface recasing, which is the only such case measured
  here.
- **Identity.** Words joined by single spaces equal the greedy text on all 7,008 rows.
- **"Teach once" fails, in both arms.** The data script derived a heard-as form for 55 terms from wave 1's
  baseline misses, aligning hypothesis words to the term as a user might teach it from History. Many are
  ordinary words or single characters: `I` and `am` for IAM, `needs` for Kubernetes, `view` for Vue, `dis`
  for Redis, `2` for Argon2, `larger` for Clojure.
  - As exact heard-as forms in the text stage alone they raise hits from 184 to 211, but rewrite 227 of 6,583
    real-speech rows and 22 of 120 hard negatives (`am` → `IAM`, `needs` → `Kubernetes`, `view,` → `Vue,`).
    The text stage already refuses to generalize the single characters among them.
  - Searched as spotting variants, single characters included, they add 1,472 false activations (1,432 in
    real speech) and 1,461 damaged rows at the frozen point; IAM's variant `I` alone accounts for 2,210
    candidates in the changed real-speech rows.

## Decision

Productize at `(6, 1.5, 1)` exactly as measured: the patterns are each target's canonical, its case forms and
its derived spacings (`Glossary.derivedAliases`); a heard-as form is never a spotting variant, because the
taught arm shows that the spellings users teach can be ordinary speech. Targets exclude ordinary-English and
two-character canonicals, and the two rendering rules stay. Separately, Teach accepts an ordinary English word
as a heard-as form and the text stage then rewrites that word everywhere; that is a product question for the
owners, not part of this result.
