import Foundation

/// Persistent store for series binge groups and source release fingerprints,
/// ensuring source consistency across next-episode auto-play and continue watching.
/// Keys are scoped per profile in UserDefaults.
struct BingeGroupRecord: Codable, Equatable {
    var bingeGroup: String?
    var addonName: String?
    var releaseFingerprint: String?
    var resolution: Int
    var quality: DebridStreamQuality
    var isCached: Bool
    var timestamp: Date

    init(
        bingeGroup: String? = nil,
        addonName: String? = nil,
        releaseFingerprint: String? = nil,
        resolution: Int = 0,
        quality: DebridStreamQuality = .unknown,
        isCached: Bool = false,
        timestamp: Date = Date()
    ) {
        self.bingeGroup = bingeGroup
        self.addonName = addonName
        self.releaseFingerprint = releaseFingerprint
        self.resolution = resolution
        self.quality = quality
        self.isCached = isCached
        self.timestamp = timestamp
    }
}

enum BingeGroupStore {
    private static let prefix = "nuvio.tv.bingeGroup."

    static func save(
        seriesId: String,
        bingeGroup: String?,
        addonName: String?,
        releaseFingerprint: String? = nil,
        resolution: Int = 0,
        quality: DebridStreamQuality = .unknown,
        isCached: Bool = false,
        profileId: String? = nil
    ) {
        let trimmedId = seriesId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return }

        // Clean values
        let cleanBingeGroup = bingeGroup?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalBingeGroup = (cleanBingeGroup?.isEmpty == false) ? cleanBingeGroup : nil

        let cleanAddon = addonName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalAddon = (cleanAddon?.isEmpty == false) ? cleanAddon : nil

        let cleanFingerprint = releaseFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalFingerprint = (cleanFingerprint?.isEmpty == false) ? cleanFingerprint : nil

        // Only save if at least one meaningful identifier exists
        guard finalBingeGroup != nil || finalAddon != nil || finalFingerprint != nil else { return }

        let record = BingeGroupRecord(
            bingeGroup: finalBingeGroup,
            addonName: finalAddon,
            releaseFingerprint: finalFingerprint,
            resolution: resolution,
            quality: quality,
            isCached: isCached,
            timestamp: Date()
        )

        let store = defaults(for: profileId)
        let key = prefix + trimmedId
        guard let data = try? JSONEncoder().encode(record) else { return }
        store.set(data, forKey: key)
    }

    static func save(
        seriesId: String,
        stream: NuvioStream,
        profileId: String? = nil
    ) {
        guard !SmartPlaybackSelector.isLowQualityOrTicketStream(stream) else { return }
        let tags = StreamQualityTags.parse(stream: stream)
        let res = tags.resolution > 0 ? tags.resolution : SmartPlaybackSelector.inferredResolution(for: stream)
        let fingerprint = StreamQualityTags.syntheticBingeGroup(for: stream)
        save(
            seriesId: seriesId,
            bingeGroup: stream.bingeGroup,
            addonName: stream.addonName,
            releaseFingerprint: fingerprint,
            resolution: res,
            quality: tags.quality,
            isCached: tags.isCached,
            profileId: profileId
        )
    }

    static func load(seriesId: String, profileId: String? = nil) -> BingeGroupRecord? {
        let trimmedId = seriesId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return nil }
        let store = defaults(for: profileId)
        let key = prefix + trimmedId
        guard let data = store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(BingeGroupRecord.self, from: data)
    }

    static func remove(seriesId: String, profileId: String? = nil) {
        let trimmedId = seriesId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return }
        let store = defaults(for: profileId)
        store.removeObject(forKey: prefix + trimmedId)
    }

    static func clearAll(profileId: String? = nil) {
        let store = defaults(for: profileId)
        for (key, _) in store.dictionaryRepresentation() where key.hasPrefix(prefix) {
            store.removeObject(forKey: key)
        }
    }

    static func clear(profileId: String? = nil) {
        clearAll(profileId: profileId)
    }

    private static func defaults(for profileId: String?) -> UserDefaults {
        if let profileId, !profileId.isEmpty {
            return ProfileSettings.store(for: profileId)
        }
        return ProfileSettings.current
    }
}
