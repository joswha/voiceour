import Foundation
import VoiceCore

/// The live recording leg of a dictation: microphone permission, recorder
/// start/stop, input metering with auto-stop, and the serialized system-audio
/// mute chain.
///
/// Extracted from `DictationCoordinator` as an extension rather than a separate
/// collaborator because every member here publishes to the coordinator's
/// main-actor UI state. Members that were `private` are now `internal`: Swift
/// scopes `private` to one file, so an extension in another file cannot see them.
@MainActor
extension DictationCoordinator {
    func beginRecording(generation: AsyncGenerationGate.Token) {
        let snapshot = tracker.snapshot()
        target = snapshot
        pendingSuggestions = []
        updateTargetLabel(for: snapshot)
        let shouldMuteSystemAudio = settings.muteSystemAudioDuringCapture

        Task { @MainActor in
            // A cancel/restart queued ahead of this task must win: without
            // this guard a stale task would start an orphaned capture and
            // overwrite the newer session's state with .recording.
            guard generations.isCurrent(generation), state == .checkingPermissions else { return }

            let audioMuter = audioMuter
            // Arm this session's restore before the mute is enqueued: from here
            // on some path owes the user a restore, whether or not the mute has
            // resolved and published `isSystemAudioMuted` yet.
            systemAudioRestore = nil
            let muteTask = enqueueMuteOperation { () -> Bool in
                shouldMuteSystemAudio ? await audioMuter.mute() : false
            }
            pendingMuteResult = muteTask

            let startError: Error?
            do {
                // Starting capture in parallel accepts a few tens of milliseconds of system-audio bleed.
                try recorder.start()
                state = .recording
                startInputMetering()
                startError = nil
            } catch {
                startError = error
            }

            let muted = await muteTask.value
            let ownsStart =
                generations.isCurrent(generation)
                && (startError == nil ? state == .recording : state == .checkingPermissions)
            guard ownsStart else {
                // A stale start task must not restore audio -- or clear the
                // mute flags -- after a newer generation has taken ownership
                // of the mute; a newer .checkingPermissions/.recording session
                // owns both the muter and the published mute state.
                if !(state == .checkingPermissions || state == .recording) {
                    if muted {
                        // Through the shared restore, not straight to the muter:
                        // a cancel or a quit may already have claimed this
                        // session's restore while this stale task was still
                        // awaiting its mute, and calling the muter directly here
                        // restored a second time.
                        await restoreSystemAudioIfNeeded()
                        guard
                            generations.isCurrent(generation)
                                || !(state == .checkingPermissions || state == .recording)
                        else { return }
                    }
                    isSystemAudioMuted = false
                }
                return
            }

            isSystemAudioMuted = muted
            // The device the user is listening on may offer no mute and no
            // volume control at all -- a DisplayPort monitor is the measured
            // case. Saying so beats a settings pane that promises a mute the
            // hardware silently refused.
            isSystemAudioMuteUnavailable = shouldMuteSystemAudio && !muted

            if let startError {
                await restoreSystemAudioIfNeeded()
                guard generations.isCurrent(generation), state == .checkingPermissions else { return }
                stopInputMetering()
                state = .error(.internalError)
                errorMessage = startError.localizedDescription
                clearCapturedTargetAndRefreshLabel()
            }
        }
    }

    func startInputMetering() {
        stopInputMetering(reset: false)
        inputMeter.update(level: recorder.currentInputLevel() ?? 0)
        inputMeter.setLive(recorder.captureIsLive())
        let autoStopEnabled = settings.autoStopEnabled
        let autoStopSilenceMs = settings.autoStopSilenceMs
        let runtime = runtime
        inputMeteringTask = Task { [weak self] in
            var autoStopDetector =
                autoStopEnabled
                ? AutoStopDetector(silenceDwellMs: autoStopSilenceMs)
                : nil
            while !Task.isCancelled {
                try? await runtime.sleep(40_000_000)
                if Task.isCancelled { break }

                let shouldContinue = await MainActor.run { [weak self] () -> Bool in
                    guard let self, self.state == .recording else { return false }
                    let level = self.recorder.currentInputLevel() ?? 0
                    self.inputMeter.update(level: level)
                    if !self.inputMeter.live, self.recorder.captureIsLive() {
                        self.inputMeter.setLive(true)
                    }
                    if autoStopDetector?.observe(level: level, at: runtime.now()) == true {
                        self.stopAndProcess()
                        return false
                    }
                    return true
                }
                if !shouldContinue { break }
            }
        }
    }

    func stopInputMetering(reset: Bool = true) {
        inputMeteringTask?.cancel()
        inputMeteringTask = nil
        if reset {
            inputMeter.reset()
        }
    }

    /// A denied microphone is a precondition that was never met, not a session
    /// that failed: nothing was captured and nothing was lost. So it reports the
    /// reason and returns to idle, the same shape as a cancel, rather than parking
    /// the coordinator in `.error` until the next successful dictation — which
    /// would leave the menu-bar dot crimson long after the user had granted
    /// permission. `errorMessage` survives the reset, and the durable readout is
    /// System → READINESS → Microphone, which offers the System Settings deep
    /// link that actually fixes it.
    func failMicrophonePermissionDenied() {
        stopInputMetering()
        state = .error(.backendUnavailable)
        errorMessage = "Microphone permission denied."
        clearCapturedTargetAndRefreshLabel()
        resetToIdleWhenInactive()
    }

    /// Serializes every muter operation FIFO. Actor jobs alone are not
    /// ordered, so without this a stale session's queued restore could run
    /// AFTER a newer session's mute and silently unmute a live capture.
    @discardableResult
    func enqueueMuteOperation<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> Task<T, Never> {
        let previous = muteOperationChain
        let next = Task { () -> T in
            await previous?.value
            return await operation()
        }
        muteOperationChain = Task { _ = await next.value }
        return next
    }

    /// Restores system audio exactly once per session, and every caller waits for
    /// it — including the one that did not start it.
    ///
    /// Four paths race to restore: the stop pipeline as soon as capture ends, its
    /// catch blocks when a throw beat that point, `cancel()` on its own task, and
    /// `prepareForTermination()`. Cancelling during finalizing or transcribing
    /// reaches two of them at once, so the deduplication cannot live in any single
    /// caller.
    ///
    /// The first caller creates the restore task; later callers await that same
    /// task. Awaiting rather than returning early is the part that matters:
    /// `applicationShouldTerminate` calls `Darwin.exit` as soon as
    /// `prepareForTermination()` returns, so a terminating path that merely
    /// observed "someone else is restoring" would exit with the audio still muted.
    ///
    /// The restore also waits on `pendingMuteResult`, because a quit can land in
    /// the window where the device is already muted but `isSystemAudioMuted` has
    /// not been published yet. Durable ownership from a crashed run is not this
    /// function's job: `SystemAudioMuter.init` and `VoiceOourApp.init` both call
    /// `recoverDurableOwnershipIfNeeded()`, and `restore()` no-ops on nil ownership.
    func restoreSystemAudioIfNeeded() async {
        if let inFlight = systemAudioRestore {
            await inFlight.value
            return
        }

        let audioMuter = audioMuter
        // Created and stored without an intervening await, so two main-actor
        // callers cannot both reach the creation path.
        let restore = Task { @MainActor in
            _ = await self.pendingMuteResult?.value
            await self.enqueueMuteOperation { await audioMuter.restore() }.value
            self.isSystemAudioMuted = false
        }
        systemAudioRestore = restore
        await restore.value
    }
}
