import CoreGraphics

/// Stand-in for the app's design tokens (Sources/Voiceour/DesignTokens.swift), which also
/// carry SwiftUI styling this harness has no use for. The copied RecordingOverlayLayout.swift
/// reads only these two spacing values, and only for panel placement. The raster path reads
/// `RecordingOverlayMetrics.islandSize` and the speech thresholds, which come from the
/// verbatim copy itself.
enum VoiceourMetrics {
    enum Space {
        static let hair: CGFloat = 2
        static let lg: CGFloat = 16
    }
}
