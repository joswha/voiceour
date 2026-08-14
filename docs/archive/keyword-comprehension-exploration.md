> Archived 2026-08-14. Historical research record; superseded by the current [architecture](../architecture.md), [benchmark contract](../benchmarks.md), and source tree.

# Keyword and technical-term comprehension exploration

This record preserves the measurements, conclusions, rejected approaches, and safety rationale from the superseded staged implementation exploration. It is not an implementation guide. The step-by-step build narrative and obsolete file inventory have been removed.

External-paper results retain their sources. VoiceOour-specific results below were measured on the stated historical checkpoint. The project policy budget used by the exploration was an overall WER increase no greater than **0.35 percentage points**; proposed thresholds were never substitutes for calibration.

## Problem: a lossy channel with asymmetric costs

The microphone does not understand `kubectl`, `NSPasteboard`, or a project-specific symbol. It converts pressure into samples, and the recognizer resolves those samples using an acoustic model whose language prior favors common words:

\[
p_m(t)=(h_{\mathrm{room}}*p_s)(t)+n_{\mathrm{air}}(t)
\]

\[
x[n]=Q_b\left(\operatorname{clip}\left(A[(h_{\mathrm{mic}}*p_m)(n/F_s)+n_e]\right)\right)
\]

\[
\hat W=\arg\max_W P_\theta(W\mid X)
\]

The TDT score already combines acoustic evidence and a learned language prior. Decoder bias or a downstream language model adds another prior; it does not create acoustic evidence that was lost.

Five failure classes require different remedies:

1. **Acquisition loss.** Noise, distance, reverberation, clipping, processing artifacts, or endpoint truncation destroy phonetic evidence before ASR.
2. **Model/search error.** The correct pronunciation is plausible, but greedy search selects common-language tokens.
3. **Representation collapse.** Keeping only one text hypothesis discards evidence that could distinguish a search error from ordinary speech.
4. **Canonical ambiguity.** Audio cannot determine `Rust` versus “rust,” `C` versus “sea,” or the casing and separators in `NSPasteboard`. Exact orthography requires side information.
5. **Rewrite-authority error.** ASR found the right term, but later cleanup or refinement changed it. This is excessive rewrite authority, not missing acoustic vocabulary.

The product cost is asymmetric: a missed technical term is inconvenient; a plausible false substitution can silently change code, commands, names, or meaning. Candidate retrieval may be permissive. Automatic replacement must be conservative, calibrated, and able to return **KEEP**.

The durable decision spine was:

- establish an acoustic quality floor;
- make spelling, case, and symbols expressible through explicit literal composition;
- preserve unmodified ASR alternatives and scores;
- retrieve a small vocabulary scoped to the captured target;
- authorize replacement only when independent evidence makes it safer than KEEP;
- learn authority only from explicit user labels.

## Capture conclusions

- In a free field, direct level falls about 6 dB per distance doubling. Moving from 60 cm to 15 cm gives roughly +12 dB direct level and usually improves the direct-to-reverberant ratio.
- A close directional or headset microphone can preserve weak fricatives, stop releases, consonant clusters, and word-final sounds under noise. It helps all speech; it is not a technical-term recognition mode.
- Once speech is clipped, masked, or truncated, downstream text models can only substitute prior.
- A 16 kHz recognition model has an 8 kHz Nyquist limit. Native-rate capture and controlled conversion may avoid opaque resampling, but do not give the model extra post-conversion bandwidth.
- Ideal 16-bit quantization SNR is about 98 dB; room noise, microphone self-noise, gain, clipping, and OS processing are usually tighter limits.
- Denoise, AGC, Voice Processing, or Sound Isolation may improve SNR while suppressing unusual phonetic detail. Each needs a paired same-audio challenge rather than a default assumption.
- Route, actual format, clipping, active speech level, estimated noise floor/SNR, endpoint energy, and possible truncation are more actionable than aggregate WER alone.
- Native-rate conversion, endpoint padding, and OS processing must be crossed with quiet/noise/echo, distance, clipping, Bluetooth, and route changes. Technical-term accuracy and false replacement are primary; generic SNR and WER are secondary.

Audio used for comparison remains ephemeral. An unprocessed reference may live only until all live-session evidence consumers finish and must then be deleted on success, cancellation, and error.

## Cross-cutting conclusions

1. **Exact technical orthography is often absent from audio.** Better capture narrows uncertainty; it cannot determine casing, separators, or a novel spelling.
2. **Preserve evidence before adding intelligence.** Waveform → features → encoder → greedy token → normalized text is a chain of lossy functions. N-best hypotheses, alignments, and unmodified scores preserve more decision-relevant information than one-best text.
3. **Retrieval is not authorization.** G2P distance, text similarity, project presence, decoder boost, and model confidence can rank candidates; none alone proves the user spoke one.
4. **Source trust dominates list size.** Explicit corrections and selected lexicons are useful. Repository presence is weak evidence because dependencies, generated symbols, stale branches, and malicious identifiers can poison the list.
5. **False replacements dominate risk.** More candidates create a multiple-comparisons problem. TurboBias's 20k-list experiment worsened WER from 9.86 to 11.42; a large noisy open-vocabulary list similarly produced negligible recall gain while hurting overall accuracy.
6. **Generic language-model correction is not the default answer.** Relevant correction studies regressed strong ASR baselines. A model may challenge a deterministic selector but must not create canonical strings or claim acoustic confidence.
7. **Learning requires labels.** Output recency, emitted transcripts, and inferred aliases create self-reinforcing loops. Only explicit acceptance or correction may raise authority.

Operationally: **preserve acoustics, retrieve broadly enough to find the term, authorize narrowly enough to protect ordinary speech, and abstain whenever evidence is missing or ambiguous.**

## Historical Parakeet feasibility findings

The installed `parakeet-mlx` 0.5.2 source was inspected at exploration time. These findings explained the eventual gates:

| Capability | Historical finding |
|---|---|
| Beam search | Implemented as a configuration choice, but benefit for the pinned checkpoint was unmeasured. Existence was not evidence of a cheap quality win. |
| Per-token confidence | Present but crude and uncalibrated. Greedy confidence used normalized entropy while beam confidence used exponentiated token and duration log probabilities, so the modes did not share semantics. |
| N-best readout | Hypotheses were built and then discarded after selecting one best path. Preserving ranked paths required a decoder fork before selection. |
| Token/trie bias | No hotword or logits-processor seam existed. Bias needed insertion before beam normalization and before greedy argmax, with separate trie state and no blank/duration boost. |
| Written term to token IDs | The exposed tokenizer decoded but did not encode. Trie compilation first needed validated deterministic segmentation or enumeration of representable decompositions. |
| CTC word spotting | Blocked on the same encoder because the pinned checkpoint had no CTC/phoneme head. A spotter required a separate model. |
| Neural biasing/adapters | Required retraining and exportable weights unavailable for the checkpoint, so it belonged to research rather than the near-term product. |

The conclusion was that shallow-fusion biasing was feasible without retraining but required a maintained decode fork, a protocol change, and a real segmentation solution. Beam and confidence needed measurement and calibration; a small N-best fork was the higher-value first evidence surface.

## Retrieval, authorization, and trust

A bounded candidate snapshot may combine confirmed aliases, selected project terms, pronunciations, and ephemeral context from the **captured target**. Those sources do not have equal authority:

- exact, user-confirmed aliases may apply deterministically in scope;
- unseen phonetic and project matches remain candidate or suggestion evidence;
- ephemeral context is memory-only and invalidates on focus change;
- project-derived and ephemeral records never enter network prompts;
- canonical output resolves only from a stored local term identifier.

G2P can derive multiple pronunciations and find “cube cuddle” near `kubectl`, but G2P is neither tokenizer segmentation nor proof that the term was spoken. Candidate retrieval and final edit authority must remain separate.

For evidence \(e\), latent truth \(z\), and action
\(a \in \{\mathrm{KEEP}, \mathrm{replace}(t), \mathrm{suggest}\}\):

\[
R(a\mid e)=\sum_z L(a,z,\mathrm{target},\mathrm{termRisk})P(z\mid e)
+L_{\mathrm{latency}}+L_{\mathrm{privacy}}+L_{\mathrm{interaction}}
\]

Authorize `replace(t)` only when its calibrated upper-risk bound is below both KEEP and suggest and every provenance, span, and security guard passes. With a false replacement cost 100 times a miss and zero correct-action cost, the illustrative threshold is above \(100/101 \approx 0.9901\). That input must be a calibrated probability for the relevant source, list size, backend, noise, and risk stratum—not a softmax, edit distance, beam score, boost score, or model-reported confidence.

The safe applicator accepts only KEEP, suggest, or an opaque existing term ID. It revalidates the span and generation, resolves canonical text locally, rejects unsafe Unicode and overlap, applies non-overlapping patches right-to-left, and locks accepted terms before optional style refinement. Missing evidence, timeout, invalid output, low margin, stale scope, or ambiguity all resolve to KEEP.

## Measurements and implementation outcome

At the 2026-07-19 checkpoint, the staged mechanisms had been implemented behind gates. The quality numbers came from a **16-case text-to-speech smoke tier** on the production Parakeet-v3 path on an M4 Pro. They were explicitly not real-speaker release proof.

### Baseline and safe vocabulary surface

The smoke baseline measured:

| Metric | Result |
|---|---:|
| Canonical-term recall | 0.636 |
| Canonical-term precision | 1.0 |
| Hard-negative false replacement | 0.0 |
| Overall WER | 0.067 |

The implemented vocabulary surface separated trust and scope, sanitized imported terms, supported literal composition and explicit correction/teaching, recorded accept/reject labels, filtered network-ineligible terms, and produced exact patches. Unseen matches were suggestion-only.

### Preserved evidence

Additive result fields carried timed words, mode-specific confidence, ranked hypotheses, pre-bias raw scores, and decoder information. On the smoke tier, beam N-best did **not** beat greedy one-best: canonical recall was 0.545 versus 0.636, and the intended terms were absent from the whole beam in the misses. This killed the assumption that beam search alone would recover the vocabulary.

The deterministic KEEP/suggest/replace authorizer was implemented default-off pending real-speaker calibration. Accepted terms were locked through later refinement. The default-off decision was a safety result, not incomplete wiring.

### Decoder bias

Phrase-trie shallow fusion and written-term segmentation were implemented as an opt-in experiment while retaining unboosted raw scores. Unconditional per-utterance bias produced:

| Smoke metric | Baseline | Biased |
|---|---:|---:|
| Canonical-term recall | 0.636 | 0.636 |
| Hard-negative false replacement | 0.0 | 0.4 |
| Overall WER | 0.067 | 0.192 |

Bias gained no recall and regressed WER by **12.5 percentage points**, far beyond the 0.35-point budget. It therefore remained disabled. Any future activation requires real-speaker data, calibrated per-term boosting, surrounding-word and prefix tests, and independent zero-boost evidence.

### Separate detector gate

On the beam smoke run, **5 of 11 intended terms (0.455)** were absent from the entire N-best list, so reranking could not recover them. A CTC spotter could not reuse the pinned encoder because the checkpoint had no CTC head. A separate detector would add another model asset, acoustic pass, latency, memory, and maintenance burden. It was deferred until real-speaker data proves frequent N-best absence and a candidate model adds recall at the required false-accept rate.

The highest-value missing prerequisite was a consented real-speaker TechTerms corpus. Automatic replacement, bias, and a second detector all depended on it; TTS was never accepted as a substitute.

## Rejected or dominated approaches

These were recorded so they would not be casually re-proposed:

- **Whisper-style initial prompting or TDT predictor priming.** Published zero-shot prompting improved rare/OOV WER but worsened unbiased WER 9.1→11.6 and overall WER 10.3→12.1, far beyond the policy budget. The pinned TDT model had no trained prompt interface.
- **Unconstrained whole-transcript language-model rewrite.** It had the largest blast radius, while directly relevant correction work reported regressions and hallucinations.
- **Continuous ASR fine-tuning from retained audio.** It violated the never-persist-audio contract. Keep an explicit correction pair, not audio.
- **Autonomous one-best G2P repair.** Phonetics is retrieval evidence only until independent acoustic or production error-channel evidence authorizes a term.
- **Output-recency learning.** Treating emitted text as a positive label makes one false choice increase its own future prior.
- **Default-on recursive project indexing.** Repository presence is weak intent evidence and expands privacy, poisoning, stale-scope, and multiple-comparison risk.
- **Always-on aggressive Voice Processing or Sound Isolation.** Retain only if paired raw-audio evaluation proves a term benefit without phonetic-detail or route regressions.
- **Decoder boost as evidence for its own replacement.** Intervention-contaminated scores are circular; authorization needs an unmodified baseline or independent scorer.

## Measurement contract retained from the exploration

A trustworthy TechTerms evaluation needs held-out terms, speakers, and acoustic conditions:

1. Jargon, acronyms, camelCase, symbols, digits, multiword names, and project coinages.
2. Unseen pronunciation variants and accents.
3. Matched hard negatives such as `C/sea/see`, `Rust/rust`, and genuine “cube cuddle” versus `kubectl`.
4. Wrong-project, stale-project, generated/dependency, malicious-Unicode, prompt-delimiter, huge-index, and symlink-escape cases.
5. Real speakers across route, distance, angle, reverberation, clipping, quiet/noise/echo, and Bluetooth conditions.
6. Candidate-list sweeps from zero through small scoped sets to deliberately excessive lists.

Use paired same-utterance comparisons for capture, processing, and ASR changes. Report:

- exact canonical precision/recall/F1 and rare-word WER;
- Candidate Recall@1/@5 and N-best oracle coverage;
- selector accuracy conditional on candidate presence;
- accepted-repair precision with measured term prevalence;
- false replacements per negative span and per 10k words, stratified by source and risk;
- reliability, ECE/Brier, and risk-coverage curves;
- untouched-span preservation and harmful non-term edits;
- overall WER and the 0.35-percentage-point budget;
- p50/p95/max latency, real-time factor, energy, warm/cold RSS, and Metal peak;
- capture noise floor/SNR, clipping/crest factor, high-band energy, endpoint truncation, route/format failures, and processing latency.

Precision targets must include prevalence. At term prevalence 0.001 and sensitivity 0.8, 99.5% precision requires a false-positive rate around \(4\times10^{-6}\). Zero errors in about 30,000 independent negative opportunities gives only a one-sided 95% upper bound near \(10^{-4}\); correlated words require more utterances, speakers, and projects.

Before testing a selector, report whether the correct canonical is in the shortlist and whether independent acoustic support exists. Never calibrate or authorize on the same score used to boost the candidate.

## Privacy constraints

- Never read, snapshot, or restore the previous clipboard. Insertion remains write-only.
- Never persist session audio. Delete ephemeral recordings and references after all evidence consumers finish.
- Never collect vocabulary through system-wide keystrokes, event taps, Accessibility text values, window titles, screen/OCR, browser history, or email history.
- Project context requires explicit root selection and a bounded, previewable importer. Retain approved names, not source bodies; never follow symlinks outside the selected root.
- Treat repository identifiers as attacker-controlled. Reject bidi controls, unsafe default-ignorables, controls, prompt delimiters, and unsafe display/log forms.
- Filter project-derived, ephemeral, pronunciation, audio, embedding, and correction-history records before constructing any network payload.
- Keep transcripts and learned vocabulary local and clearable. Clearing includes aliases, tombstones, pronunciation/retrieval indexes, snapshots, caches, and speaker-sensitive derived records.
- Never raise term authority from the system's own transcript or refinement output.

## Evidence gaps left open

The historical work deliberately did not answer these without real-speaker data:

- whether stable ranked path scores and candidate forced scoring justify decoder-fork maintenance;
- which replacement threshold reflects real prevalence and user-visible cost by target and term risk;
- whether native-rate capture or OS voice processing improves technical-term results without deleting rare phonetic detail;
- which explicitly selected project sources add recall without dependency/generated-symbol poisoning;
- how often the correct term is absent from N-best in real speech and whether a second detector can recover it within memory, latency, and false-accept budgets;
- whether a specialized local selector can beat the deterministic scorer after enough explicit correction pairs exist.

## Sources

Acoustics and capture:

- ITU-T P.56 active speech level: <https://www.itu.int/rec/T-REC-P.56/en>
- ITU-T P.835 speech/noise/overall quality: <https://www.itu.int/rec/T-REC-P.835/en>
- DNS Challenge: <https://arxiv.org/abs/2303.11510>
- URGENT speech enhancement lessons: <https://arxiv.org/abs/2506.01611>
- Far-field ASR tutorial: <https://arxiv.org/abs/2009.09395>
- Apple AVAudioEngine configuration changes: <https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification>
- Apple AVAudioConverter: <https://developer.apple.com/documentation/avfaudio/avaudioconverter>
- Apple AVAudioInputNode: <https://developer.apple.com/documentation/avfaudio/avaudioinputnode>

Contextual ASR and retrieval:

- TurboBias phrase-trie shallow fusion: <https://arxiv.org/abs/2508.07014>
- CTC word spotting: <https://arxiv.org/abs/2406.07096>
- Streaming CTC word spotting: <https://arxiv.org/abs/2605.18222>
- BR-ASR large-list learned retrieval: <https://arxiv.org/abs/2505.19179>
- Massive open-vocabulary keyword spotting: <https://arxiv.org/abs/2606.11279>
- CLAS: <https://arxiv.org/abs/1808.02480>
- Density-ratio language-prior correction: <https://arxiv.org/abs/2002.11268>

Correction, uncertainty, and personalization:

- Retrieval-augmented named-entity correction: <https://arxiv.org/abs/2409.06062>
- Specialized ECLM/denoising LM v2: <https://arxiv.org/abs/2405.15216v2>
- HyPoradise N-best correction: <https://arxiv.org/abs/2309.15701>
- Prompt-only ASR correction comparison: <https://arxiv.org/abs/2307.04172>
- Selective classification/rejection: <https://arxiv.org/abs/1705.08500>
- Neural-network calibration: <https://arxiv.org/abs/1706.04599>
- Continuous personalization drift/acceptance criteria: <https://www.isca-archive.org/interspeech_2021/sim21_interspeech.html>

Pronunciation and security:

- PanPhon: <https://aclanthology.org/C16-1328/>
- CMUdict: <https://github.com/cmusphinx/cmudict>
- eSpeak-ng: <https://github.com/espeak-ng/espeak-ng>
- Indirect prompt injection: <https://arxiv.org/abs/2302.12173>
- Trojan Source/Unicode bidi risk: <https://arxiv.org/abs/2111.00169>
