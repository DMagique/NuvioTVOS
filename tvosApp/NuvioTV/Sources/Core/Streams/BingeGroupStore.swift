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
    private static let storageDirectoryName = "bingeGroups"
    private static let maxEntries = 200
    private static let lock = NSLock()

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

        lock.lock()
        defer { lock.unlock() }

        var records = loadRecords(profileId: profileId)
        records[trimmedId] = record
        persistRecords(records, profileId: profileId)

        // Clear legacy UserDefaults key if present
        let store = defaults(for: profileId)
        store.removeObject(forKey: prefix + trimmedId)
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

        lock.lock()
        defer { lock.unlock() }

        let records = loadRecords(profileId: profileId)
        if let record = records[trimmedId] {
            return record
        }

        // Legacy fallback from UserDefaults
        let store = defaults(for: profileId)
        let key = prefix + trimmedId
        if let data = store.data(forKey: key),
           let record = try? JSONDecoder().decode(BingeGroupRecord.self, from: data) {
            var updated = records
            updated[trimmedId] = record
            persistRecords(updated, profileId: profileId)
            store.removeObject(forKey: key)
            return record
        }
        return nil
    }

    static func remove(seriesId: String, profileId: String? = nil) {
        let trimmedId = seriesId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        var records = loadRecords(profileId: profileId)
        if records.removeValue(forKey: trimmedId) != nil {
            persistRecords(records, profileId: profileId)
        }
        let store = defaults(for: profileId)
        store.removeObject(forKey: prefix + trimmedId)
    }

    static func clearAll(profileId: String? = nil) {
        lock.lock()
        defer { lock.unlock() }

        let key = storageKey(for: profileId)
        LargePayloadStore.remove(key: key, directory: storageDirectoryName)

        let store = defaults(for: profileId)
        for (k, _) in store.dictionaryRepresentation() where k.hasPrefix(prefix) {
            store.removeObject(forKey: k)
        }
    }

    static func clear(profileId: String? = nil) {
        clearAll(profileId: profileId)
    }

    private static func storageKey(for profileId: String?) -> String {
        let id = profileId ?? ProfileSettings.activeProfileID ?? "default"
        return "bingeGroups.\(id)"
    }

    private static func loadRecords(profileId: String?) -> [String: BingeGroupRecord] {
        let key = storageKey(for: profileId)
        if let data = LargePayloadStore.read(key: key, directory: storageDirectoryName),
           let decoded = try? JSONDecoder().decode([String: BingeGroupRecord].self, from: data) {
            return decoded
        }

        // Migrate any legacy records found in UserDefaults
        let store = defaults(for: profileId)
        var migrated: [String: BingeGroupRecord] = [:]
        for (k, _) in store.dictionaryRepresentation() where k.hasPrefix(prefix) {
            let seriesId = String(k.dropFirst(prefix.count))
            if let data = store.data(forKey: k),
               let record = try? JSONDecoder().decode(BingeGroupRecord.self, from: data) {
                migrated[seriesId] = record
            }
            store.removeObject(forKey: k)
        }
        if !migrated.isEmpty {
            persistRecords(migrated, profileId: profileId)
        }
        return migrated
    }

    private static func persistRecords(_ records: [String: BingeGroupRecord], profileId: String?) {
        let bounded = Dictionary(
            uniqueKeysWithValues: records
                .sorted { $0.value.timestamp > $1.value.timestamp }
                .prefix(maxEntries)
                .map { ($0.key, $0.value) }
        )
        let key = storageKey(for: profileId)
        if bounded.isEmpty {
            LargePayloadStore.remove(key: key, directory: storageDirectoryName)
            return
        }
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        LargePayloadStore.write(data, key: key, directory: storageDirectoryName)
    }

    private static func defaults(for profileId: String?) -> UserDefaults {
        if let profileId, !profileId.isEmpty {
            return ProfileSettings.store(for: profileId)
        }
        return ProfileSettings.current
    }
}
