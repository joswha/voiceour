# Session cue earcons — design

Status: **proposed, awaiting review.** Date: 2026-08-24.

Two short synthesized cues mark the boundaries of listening: a rising glide when
capture opens, the same glide inverted when capture ends. Nothing else in the app
gains a sound.

## Problem

The recording island is the only signal that Voiceour is listening, and it appears
on a `.screenSaver`-level panel the user is not looking at — their eyes are on the
text field they are dictating into. The gesture that starts a session is a single
solitary Fn/Globe tap with no key travel and no visible target, so the two
questions a user actually has are "did that register?" and "is it listening now?".
Both are answerable in under 200 ms by sound and by nothing else the app currently
does.

## Constraints measured in this repository

| fact | source |
| --- | --- |
| No audio playback exists anywhere in the app. `NSSound`, `AVAudioPlayer`, `AudioServicesPlaySystemSound` appear zero times in `Sources/`. | grep |
| No target declares `resources:`. Shipping an audio asset would add resource handling to `Package.swift` *and* to `scripts/bundle_app.sh`, plus a binary blob to git. | `Package.swift` |
| System audio is muted during capture **by default** (`muteSystemAudioDuringCapture = true`). | `Sources/VoiceCore/Models.swift` |
| The mute is a staircase: volume ramps to zero in 8 steps over 120 ms, then the hardware mute is written. Restore lifts the mute first and ramps volume 0→prior over another 120 ms. | `SystemAudioMuter.fadeDuration`, `fadeSteps`, `mute()`, `restore()` |
| The island appears at `.checkingPermissions` — on the tap, before the microphone opens — and fades in over `VoiceourMotion.standardDuration` (0.18 s), ease-out. | `RecordingOverlayController.show()` |
| `beginRecording` starts capture and the mute concurrently and already accepts up to 120 ms of decaying system-audio bleed at the head of every WAV. | `RecordingSessionDriver.swift:56` |
| The stop path is: await `pendingMuteResult` → `recorder.stop()` finalizes the WAV → `beginSystemAudioRestore()` starts the 120 ms restore ramp and is deliberately **not** awaited. | `TranscriptProcessingPipeline.processStop` |
| `DictationRuntime.sleep` is the injectable clock seam; the flow harness pins it. | `DictationRuntime.swift` |
| The port pattern for a side effect is a small `Sendable` protocol in `CorePorts.swift` plus a no-op conformance — `SystemAudioMuting` / `NoOpSystemAudioMuter`. | `CorePorts.swift` |
| Sound is not a declared non-goal. | `docs/v0-non-goals.md` |

The load-bearing consequence: **the app mutes the device it would play the cue
through.** A cue fired at the tap is ducked by our own fade; a cue fired at the
stop tap is inaudible, because the hardware mute is still set. Every decision
below follows from that collision, not from taste.

## Decisions

### D1 — Synthesize the cues, do not ship assets

`VoiceCore` computes the samples as pure math and hands over an in-memory WAV.
This costs no `Package.swift` resource declaration, no bundle-script change, no
binary in git, and it keeps the sound design as a readable parameter table that
tests can assert on. `VoiceCore` stays Foundation-only: `Data` and `sin` are both
available there.

Rejected: bundled WAV/CAF (three new moving parts, opaque diff, and the same
playback code anyway); `NSSound(named: "Tink")` and friends (generic system
alerts, wrong sound, and they follow the alert-volume slider rather than the
output volume).

### D2 — One voice, mirrored in pitch, never in time

| parameter | up cue | down cue |
| --- | --- | --- |
| duration | 140 ms | 140 ms |
| glide | 620 → 1240 Hz (exponential, one octave) | 1240 → 620 Hz |
| pitch overshoot | +5% at 80% of the way, settling back | −5%, settling back |
| second harmonic | −15 dB (0.18 relative) | same |
| attack / release | 7 ms / 55 ms raised cosine | same |
| peak | −16.9 dBFS | same |

The down cue mirrors the **pitch contour** and keeps a forward envelope. A
time-reversed cue — slow swell, abrupt cut — reads as a backwards or sucking
sound, which is exactly the wrong affect for "done, delivering".

The second harmonic and the small overshoot are what separate a "wheep" from a
test tone: without them a pure glide reads as a sine sweep, which is thin at the
volume this has to sit at.

### D3 — 140 ms, tied to the app's timing vocabulary

`VoiceourMotion.quickDuration` is 0.14 s and the island's entrance is 0.18 s, so
the cue finishes just before the island reaches full opacity: one gesture, two
senses. A 180 ms variant exists for comparison but makes the mute deferral in D5
40 ms more expensive.

### D4 — Output volume is the volume control

The cue plays at a fixed −16.9 dBFS peak into the default output device, so the
user's own volume knob is the only level control. No app-side volume slider and
no alert-volume coupling.

### D5 — Start: the cue owns its window, the microphone does not wait

The cue fires from `beginRecording`, inside the existing `Task { @MainActor }`
and after its `generations.isCurrent(generation), state == .checkingPermissions`
guard — the same site that opens capture, so a stale start or a denied
microphone never makes a sound. The island appears earlier, at
`.checkingPermissions`; the cue deliberately marks the microphone opening rather
than the tap, and for an already-granted microphone those are the same
main-actor turn.

Order inside that task, preserving today's arming order exactly:

1. Play the up cue (fire-and-forget).
2. Enqueue the mute operation as today — synchronously, so `pendingMuteResult`
   is armed before anything can await it — but with the closure now sleeping for
   the cue duration, re-checking the recording generation on the main actor, and
   only then calling `mute()`.
3. `recorder.start()` — unchanged, immediate. The microphone never waits for a
   sound.

Cost: the head of the WAV gains up to 140 ms of full-volume system audio plus our
own −16.9 dBFS chirp, on top of the 120 ms of decaying bleed the pipeline already
accepts. Benefit: zero added latency to microphone open, and the cue is heard
whole.

Rejected: **pre-roll** (open the microphone only after the cue) — it adds 140 ms
before capture and clips the first syllable of anyone who taps and talks, which
is the app's core gesture. Rejected: **riding the duck** (cue and ramp start
together) — free, but the cue decays to nothing as it rises; audibly a swallowed
sound. Both were rendered and compared by ear before this choice.

### D6 — Stop: the cue waits for the device to come back

The down cue fires after `recorder.stop()` has finalized the WAV **and** the
restore ramp has finished, by chaining on the task `beginSystemAudioRestore()`
already returns. When no mute was held — the setting is off, or the device offers
no controls — it fires immediately.

That puts the cue roughly 150–180 ms after the tap in the default configuration.
This is the one place the design accepts perceptible latency, because the
alternatives are worse: firing at the tap is silent (the hardware mute is still
set), and firing under the ramp makes a descending cue swell in from zero, which
is the backwards-sound failure again.

Rejected: restoring without a ramp so the cue can fire instantly and
psychoacoustically mask the step-in. It works in principle, but it gives the
muter a second restore mode whose correctness depends on the user's media level.

### D7 — Exactly two cues, at the two capture boundaries

The cues mean **"listening started"** and **"listening stopped"**. They do not
mean "delivered": ASR, cleanup and insertion all happen after the down cue, and
any of them can fail.

- The down cue fires in `stopAndProcess` for all three triggers — `.manual`,
  `.autoStop`, `.silentCapture`. Auto-stop is the case that most needs it: the app
  ended the session, not the user.
- **Cancel plays nothing.** Escape means the audio was thrown away; the down cue
  would promise the opposite, and the island's exit already reports it.
- No delivery cue, no failure cue, no copy-only cue in v1. Copy-only delivery is
  the strongest future candidate — nothing appears in the target app and the user
  must press ⌘V — but it needs its own design pass and a third sound with a
  distinct meaning, not a reused chirp.

### D8 — One setting, default on

`Settings.sessionSoundsEnabled: Bool = true`, JSON key `session_sounds_enabled`,
decoded with `decodeIfPresent ?? default` like every sibling. Surfaced in
**General → Audio**, beside the mute-during-capture row:

> Play a sound when listening starts and stops

Default on: an awareness cue that ships off is an awareness cue nobody ever hears.

### D9 — Injected port, silent in tests and the harness

`SessionCuePlaying` in `CorePorts.swift` with a `NoOpSessionCuePlayer`, mirroring
`SystemAudioMuting`/`NoOpSystemAudioMuter`. Tests inject a recording spy; the
offscreen UI harness injects the no-op, so no harness run can make a noise. No
`RenderOverrides` field and no harness-only branch — the seam is the port.

## Architecture

| unit | responsibility | depends on |
| --- | --- | --- |
| `VoiceCore/SessionCue.swift` | `SessionCue` (`.listeningStarted`, `.listeningEnded`), `SessionCueVoice` parameter struct, `samples(sampleRate:)`, `wavData(sampleRate:)`, `duration`. Pure, deterministic, Foundation-only. | nothing |
| `VoiceCore/CorePorts.swift` | `SessionCuePlaying` port + `NoOpSessionCuePlayer`. | nothing |
| `VoiceMac/SessionCuePlayer.swift` | Actor holding one prepared `AVAudioPlayer` per cue, built once from the in-memory WAV `Data` at init and replayed by resetting `currentTime`. | `AVFoundation`, `VoiceCore` |
| `Voiceour/RecordingSessionDriver.swift` | Fires the up cue and defers the mute by the cue duration inside the existing serialized mute closure. | port, `DictationRuntime.sleep` |
| `Voiceour/TranscriptProcessingPipeline.swift` | Chains the down cue on the restore task. | port |
| `Voiceour/ConsoleGeneralTab.swift` | The one toggle. | settings |

The player never reads settings and never decides *when*; the coordinator gates
on `settings.sessionSoundsEnabled` at the call sites. One decision, one place.

```mermaid
sequenceDiagram
    participant U as User
    participant C as Coordinator
    participant P as SessionCuePlayer
    participant M as SystemAudioMuter
    participant R as Recorder
    U->>C: Fn tap
    C->>P: play(.listeningStarted)
    C->>R: start()
    C->>M: enqueue { sleep(140ms); mute() }
    Note over M: volume staircase 1→0 over 120 ms, then hardware mute
    U->>C: Fn tap
    C->>R: stop() → WAV
    C->>M: restore()  (mute lifts, 0→prior over 120 ms)
    M-->>C: restored
    C->>P: play(.listeningEnded)
    C->>C: transcribe → clean → insert
```

## Failure modes

| case | behaviour |
| --- | --- |
| `AVAudioPlayer(data:)` throws at init | Swallowed; the player becomes a no-op for the process. A missing sound is not a dictation failure and never reaches `UserFacingDictationFailure`. |
| Cancel lands inside the 140 ms deferral | The enqueued closure re-checks the recording generation before muting, so a cancelled session never ducks the user's audio. |
| Stop lands inside the deferral | `processStop` already awaits `pendingMuteResult`; it waits ≤140 ms. Bounded, and the same shape as today's concurrent mute. |
| Muting disabled, or device has no controls | No deferral at start; the down cue fires immediately at stop. |
| Setting off | No cue is constructed and no deferral is applied. Capture timing is byte-for-byte today's. |
| Output volume at zero / user's own mute | Silent. Nothing to do. |

## Testing

- **Synth suite** (`Tests/`, Swift Testing): sample count equals `round(rate × duration)`; first and last samples within 1e-4 of zero; peak within 0.5 dB of the declared level; bounded max sample-to-sample delta (no click); instantaneous frequency monotone rising for the up cue and falling for the down cue; the down cue is *not* the reverse of the up cue.
- **Settings**: default `true`; decoding a document without the key keeps `true`; round-trip.
- **Sequencing** with a spy port and a pinned `DictationRuntime`: the up cue is played before `mute()` is called; `mute()` is not called before the cue duration has elapsed on the injected clock; the down cue is played after `restore()` completes; `cancel()` plays nothing; `.autoStop` plays the down cue; the setting off plays nothing and reinstates the undeferred mute.
- **Manual audible check** on the real bundle (`scripts/run_real.sh`), mute on and off, speakers and headphones. The offscreen harness cannot render audio, so this is the only proof of the sound itself.
- **Goldens**: `make ui-update` for the new General row's AX dump and PNG digest, plus the General flow journal.

## Non-goals

No cue volume slider, no alternate cue packs, no cue for delivery, failure, or
cancel, no ducking of other applications, no alert-sound or Sound Effects
integration, no cue when the setting is off, and no persistence of anything about
the cues.
