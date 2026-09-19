import Foundation
import Darwin

/// Everything required to open a stream on any playback backend.
struct PlaybackLoadRequest: Equatable {
    var videoURL: URL
    /// Separate audio URL (YouTube trailers). Forces MPV when non-nil.
    var audioURL: URL?
    var resumePositionSeconds: Double?
    var httpHeaders: [String: String]
    var externalSubtitles: [NuvioSubtitle]
    var preferredAudioLanguages: [String]
    var preferredSubtitleLanguages: [String]
    /// Settings → Frame Rate Matching / Match Content. `false` when Off.
    var matchContentEnabled: Bool
    var cacheProfile: PlaybackCacheProfile
    var assMode: PlaybackASSMode
    var autoplay: Bool
    /// Runtime controls that must survive an Aether → MPV handoff.
    var playbackRate: Float
    var subtitleDelaySeconds: Double
    var audioDelaySeconds: Double
    var audioGainDB: Double
    /// Stream card labels used only for diagnostics / hard-exception policy.
    var streamName: String?
    var streamDescription: String?
    var filename: String?
    /// Canonical content identity (SHA-256 over imdbId/season/ep/durationBucket)
    /// allowing preview caches to survive debrid URL changes and token expiration.
    var canonicalMediaKey: String?
    /// Direct storyboard/trickplay manifest URL (WebVTT) when supplied by the stream add-on.
    var trickplayURL: URL?
    /// Remote artwork URL (episode thumbnail or movie poster/backdrop) for system Now Playing publication.
    var artworkURL: URL?

    init(
        videoURL: URL,
        audioURL: URL? = nil,
        resumePositionSeconds: Double? = nil,
        httpHeaders: [String: String] = [:],
        externalSubtitles: [NuvioSubtitle] = [],
        preferredAudioLanguages: [String] = [],
        preferredSubtitleLanguages: [String] = [],
        matchContentEnabled: Bool = true,
        cacheProfile: PlaybackCacheProfile = .auto,
        assMode: PlaybackASSMode = .strip,
        autoplay: Bool = true,
        playbackRate: Float = 1,
        subtitleDelaySeconds: Double = 0,
        audioDelaySeconds: Double = 0,
        audioGainDB: Double = 0,
        streamName: String? = nil,
        streamDescription: String? = nil,
        filename: String? = nil,
        canonicalMediaKey: String? = nil,
        trickplayURL: URL? = nil,
        artworkURL: URL? = nil
    ) {
        self.videoURL = videoURL
        self.audioURL = audioURL
        self.resumePositionSeconds = resumePositionSeconds
        self.httpHeaders = httpHeaders
        self.externalSubtitles = externalSubtitles
        self.preferredAudioLanguages = preferredAudioLanguages
        self.preferredSubtitleLanguages = preferredSubtitleLanguages
        self.matchContentEnabled = matchContentEnabled
        self.cacheProfile = cacheProfile
        self.assMode = assMode
        self.autoplay = autoplay
        self.playbackRate = playbackRate
        self.subtitleDelaySeconds = subtitleDelaySeconds
        self.audioDelaySeconds = audioDelaySeconds
        self.audioGainDB = audioGainDB
        self.streamName = streamName
        self.streamDescription = streamDescription
        self.filename = filename
        self.canonicalMediaKey = canonicalMediaKey
        self.trickplayURL = trickplayURL
        self.artworkURL = artworkURL
    }
}

enum PlaybackCacheProfile: String, Equatable {
    case auto
    case conservative
    case medium
    case large
    case max
    case ultra

    /// Maps Settings → Network Cache raw value.
    static func fromSettings(_ raw: String?) -> PlaybackCacheProfile {
        switch raw {
        case "Small", "Conservative": return .conservative
        case "Medium": return .medium
        case "Large": return .large
        case "Max": return .max
        case "Ultra", "Extreme": return .ultra
        default: return .auto
        }
    }

    /// Aether `LoadOptions.forwardBufferSegments` (~4 s each).
    var aetherForwardBufferSegments: Int {
        switch self {
        case .conservative: return 4
        case .medium: return 10
        case .large: return 18
        case .max: return 25
        case .ultra: return 25
        case .auto:
            return Self.resolveAutoSegments(
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                availableMemoryBytes: os_proc_available_memory()
            )
        }
    }

    /// Dynamically scales Aether forward buffer segments based on live available memory headroom and device physical memory.
    /// Safely bounded to ensure 4K VideoToolbox decoding headroom is preserved without triggering tvOS jetsam kills.
    static func resolveAutoSegments(physicalMemoryBytes: UInt64, availableMemoryBytes: size_t) -> Int {
        let gibPhysical = Double(physicalMemoryBytes) / 1_073_741_824.0
        let mbAvailable = Double(availableMemoryBytes) / (1024.0 * 1024.0)

        if gibPhysical > 3.5 && mbAvailable >= 1000 {
            return 25 // Max/Ultra: ~100s readahead
        } else if gibPhysical > 2.5 && mbAvailable >= 450 {
            return 18 // Large: ~72s readahead
        } else if mbAvailable >= 250 {
            return 10 // Medium: ~40s readahead
        } else {
            return 4  // Conservative: ~16s readahead
        }
    }
}

enum PlaybackASSMode: String, Equatable {
    case strip
    case force
    case scale

    static func fromSettings(_ raw: String?) -> PlaybackASSMode {
        switch (raw ?? "Strip").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "force": return .force
        case "scale": return .scale
        default: return .strip
        }
    }
}
