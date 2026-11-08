---
description: Runtime code is governed by docs/runtime.md
condition: '[\s\S]'
interruptMode: never
scope:
  - 'tool:edit(**/Sources/Voiceour/{DictationCoordinator,DictationRuntime,RecordingSessionDriver,TranscriptProcessingPipeline,AsyncGenerationGate,VoiceourApp,VoiceourAppDelegate,LaunchOptions,StopPathSignposts,DiagnosticsReport,RecentSessionJournal,DictationStatsJournal,SystemPrivacySettings}.swift)'
  - 'tool:write(**/Sources/Voiceour/{DictationCoordinator,DictationRuntime,RecordingSessionDriver,TranscriptProcessingPipeline,AsyncGenerationGate,VoiceourApp,VoiceourAppDelegate,LaunchOptions,StopPathSignposts,DiagnosticsReport,RecentSessionJournal,DictationStatsJournal,SystemPrivacySettings}.swift)'
  - 'tool:edit(**/Sources/VoiceMac/{ApplicationRelauncher,CaptureConverter,CaptureTelemetryAnalyzer,CoreAudioInputDevice,CoreAudioOutputDevice,CoreAudioProperty,FakeAudioRecorder,GeneralPasteboard,KeyboardShortcutsBinder,LidState,MicrophoneCapture,MicrophoneRecorder,PasteboardInserter,RecordingScavenger,SessionCuePlayer,SystemAudioMuter,SystemPermissions,WorkspaceTargetTracker}.swift)'
  - 'tool:write(**/Sources/VoiceMac/{ApplicationRelauncher,CaptureConverter,CaptureTelemetryAnalyzer,CoreAudioInputDevice,CoreAudioOutputDevice,CoreAudioProperty,FakeAudioRecorder,GeneralPasteboard,KeyboardShortcutsBinder,LidState,MicrophoneCapture,MicrophoneRecorder,PasteboardInserter,RecordingScavenger,SessionCuePlayer,SystemAudioMuter,SystemPermissions,WorkspaceTargetTracker}.swift)'
  - 'tool:edit(**/Sources/VoiceCore/{AppSupportPaths,AutoStopDetector,CaptureModels,CorePorts,DictationPolicy,DictationStats,DictationStatsCalculator,DictationStatsStore,InsertionSafetyPolicy,InsertionStateMapping,LaunchOptions,RecentSessionStore,SafetyClassifier,SessionCue,SessionState,SettingsStore,UserFacingDictationFailure}.swift)'
  - 'tool:write(**/Sources/VoiceCore/{AppSupportPaths,AutoStopDetector,CaptureModels,CorePorts,DictationPolicy,DictationStats,DictationStatsCalculator,DictationStatsStore,InsertionSafetyPolicy,InsertionStateMapping,LaunchOptions,RecentSessionStore,SafetyClassifier,SessionCue,SessionState,SettingsStore,UserFacingDictationFailure}.swift)'
  - 'tool:edit(**/Resources/*.entitlements)'
  - 'tool:write(**/Resources/*.entitlements)'
---
This file is governed by `docs/runtime.md`: dictation lifecycle, capture, insertion safety, persistence, network, environment seams and permissions. If you have not read it this session, read it before your next edit, check this edit against it, and update it in the same commit when behavior changes.
