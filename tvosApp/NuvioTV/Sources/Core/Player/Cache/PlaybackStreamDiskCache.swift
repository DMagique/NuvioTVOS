import Foundation
import OSLog

let diskCacheLog = Logger(subsystem: "com.pyksel.nuviotvos", category: "diskcache")

/// Manages chunk-based video caching to Apple TV local flash storage with a sliding-window FIFO eviction policy.
actor PlaybackStreamDiskCache {
    /// 2 MiB per chunk allows fine-grained range fetching, efficient SSD page writes, and low seek latency.
    static let defaultChunkSize: Int64 = 2 * 1024 * 1024

    nonisolated let sessionID: String
    nonisolated let fileLength: Int64
    nonisolated let chunkSize: Int64
    nonisolated let cacheDirectory: URL
    private var maxCacheSizeBytes: Int64
    private var cachedChunkIndices: Set<Int> = []
    private var chunkAccessOrder: [Int] = []

    init(
        sessionID: String,
        fileLength: Int64,
        chunkSize: Int64 = defaultChunkSize,
        maxCacheSizeBytes: Int64 = 20 * 1024 * 1024 * 1024 // 20 GB default
    ) {
        self.sessionID = sessionID
        self.fileLength = fileLength
        self.chunkSize = chunkSize
        self.maxCacheSizeBytes = maxCacheSizeBytes

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = caches.appendingPathComponent("PlaybackStreamCache", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        self.cacheDirectory = directory

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scanned = Self.scanExistingChunks(in: directory)
        self.cachedChunkIndices = scanned.chunks
        self.chunkAccessOrder = scanned.order
        Self.pruneGlobalCacheIfNeeded(maxSizeBytes: maxCacheSizeBytes, preservingSessionID: sessionID)
    }

    nonisolated var totalChunks: Int {
        guard fileLength > 0 else { return 0 }
        return Int((fileLength + chunkSize - 1) / chunkSize)
    }

    var currentCachedBytes: Int64 {
        Int64(cachedChunkIndices.count) * chunkSize
    }

    var cachedFraction: Double {
        guard fileLength > 0, totalChunks > 0 else { return 0 }
        return Double(cachedChunkIndices.count) / Double(totalChunks)
    }

    // MARK: - Chunk Operations

    nonisolated func chunkIndex(forByteOffset offset: Int64) -> Int {
        guard chunkSize > 0 else { return 0 }
        return Int(offset / chunkSize)
    }

    nonisolated func byteRange(forChunk index: Int) -> Range<Int64> {
        let start = Int64(index) * chunkSize
        let end = min(start + chunkSize, fileLength)
        return start..<end
    }

    func isChunkCached(_ index: Int) -> Bool {
        cachedChunkIndices.contains(index)
    }

    func contiguousCachedBytesAhead(of byteOffset: Int64) -> Int64 {
        let startChunk = chunkIndex(forByteOffset: byteOffset)
        let total = totalChunks
        guard startChunk < total else { return 0 }
        var contiguousChunks = 0
        for c in startChunk..<total {
            if cachedChunkIndices.contains(c) {
                contiguousChunks += 1
            } else {
                break
            }
        }
        return Int64(contiguousChunks) * chunkSize
    }

    func hasByteRangeCached(_ range: Range<Int64>) -> Bool {
        guard !range.isEmpty else { return true }
        let startChunk = chunkIndex(forByteOffset: range.lowerBound)
        let endChunk = chunkIndex(forByteOffset: max(range.lowerBound, range.upperBound - 1))
        for chunk in startChunk...endChunk {
            if !cachedChunkIndices.contains(chunk) { return false }
        }
        return true
    }

    func readChunk(_ index: Int) -> Data? {
        guard cachedChunkIndices.contains(index) else { return nil }
        let fileURL = cacheDirectory.appendingPathComponent("chunk_\(index).bin")
        guard let data = try? Data(contentsOf: fileURL) else {
            cachedChunkIndices.remove(index)
            return nil
        }
        touchChunk(index)
        return data
    }

    func writeChunk(_ index: Int, data: Data, playheadOffset: Int64 = -1) {
        let fileURL = cacheDirectory.appendingPathComponent("chunk_\(index).bin")
        do {
            try data.write(to: fileURL, options: .atomic)
            cachedChunkIndices.insert(index)
            touchChunk(index)
            enforceSlidingWindow(playheadOffset: playheadOffset)
        } catch {
            diskCacheLog.error("Failed to write chunk \(index): \(error.localizedDescription)")
        }
    }

    func readBytes(offset: Int64, length: Int) -> Data? {
        guard length > 0, offset >= 0, offset < fileLength else { return nil }
        let endOffset = min(offset + Int64(length), fileLength)
        let requiredRange = offset..<endOffset
        guard hasByteRangeCached(requiredRange) else { return nil }

        var result = Data(capacity: length)
        let startChunk = chunkIndex(forByteOffset: offset)
        let endChunk = chunkIndex(forByteOffset: endOffset - 1)

        for c in startChunk...endChunk {
            guard let chunkData = readChunk(c) else { return nil }
            let chunkRange = byteRange(forChunk: c)
            let readStart = max(offset, chunkRange.lowerBound) - chunkRange.lowerBound
            let readEnd = min(endOffset, chunkRange.upperBound) - chunkRange.lowerBound
            guard readStart >= 0, readEnd <= chunkData.count, readStart <= readEnd else { return nil }
            result.append(chunkData[Data.Index(readStart)..<Data.Index(readEnd)])
        }
        return result
    }

    // MARK: - Sliding Window & FIFO Eviction

    /// Evicts chunks farthest behind the current playhead when disk usage exceeds the allocated limit.
    func enforceSlidingWindow(playheadOffset: Int64) {
        guard currentCachedBytes > maxCacheSizeBytes else { return }
        let playheadChunk = playheadOffset >= 0 ? chunkIndex(forByteOffset: playheadOffset) : -1

        // Sort candidates: prioritize evicting chunks behind the playhead (oldest footage first)
        let sortedChunks = Array(cachedChunkIndices).sorted { a, b in
            if playheadChunk >= 0 {
                let aIsBehind = a < playheadChunk
                let bIsBehind = b < playheadChunk
                if aIsBehind && !bIsBehind { return true }
                if !aIsBehind && bIsBehind { return false }
                if aIsBehind && bIsBehind {
                    // Evict the earliest watched footage first (smallest chunk index)
                    return a < b
                }
            }
            // For future chunks beyond limit, evict the farthest ahead
            return a > b
        }

        for chunkToEvict in sortedChunks {
            guard currentCachedBytes > maxCacheSizeBytes else { break }
            deleteChunk(chunkToEvict)
        }
    }

    private func touchChunk(_ index: Int) {
        if let idx = chunkAccessOrder.firstIndex(of: index) {
            chunkAccessOrder.remove(at: idx)
        }
        chunkAccessOrder.append(index)
    }

    private func deleteChunk(_ index: Int) {
        cachedChunkIndices.remove(index)
        if let idx = chunkAccessOrder.firstIndex(of: index) {
            chunkAccessOrder.remove(at: idx)
        }
        let fileURL = cacheDirectory.appendingPathComponent("chunk_\(index).bin")
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func scanExistingChunks(in directory: URL) -> (chunks: Set<Int>, order: [Int]) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return ([], [])
        }
        var chunks = Set<Int>()
        var order = [Int]()
        for file in files where file.lastPathComponent.hasPrefix("chunk_") && file.pathExtension == "bin" {
            let name = file.deletingPathExtension().lastPathComponent
            let indexStr = name.replacingOccurrences(of: "chunk_", with: "")
            if let index = Int(indexStr) {
                chunks.insert(index)
                order.append(index)
            }
        }
        return (chunks, order)
    }

    /// Prunes older stream session cache directories if total disk cache usage across all titles exceeds maxSizeBytes.
    static func pruneGlobalCacheIfNeeded(maxSizeBytes: Int64, preservingSessionID: String) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = caches.appendingPathComponent("PlaybackStreamCache", isDirectory: true)
        guard let subdirs = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return }

        var sessionFolders: [(url: URL, date: Date, size: Int64)] = []
        var totalBytes: Int64 = 0

        for dir in subdirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
            var dirSize: Int64 = 0
            var latestDate = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            for file in files {
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                dirSize += Int64(values?.fileSize ?? 0)
                if let mod = values?.contentModificationDate, mod > latestDate {
                    latestDate = mod
                }
            }
            totalBytes += dirSize
            sessionFolders.append((url: dir, date: latestDate, size: dirSize))
        }

        guard totalBytes > maxSizeBytes else { return }
        let sorted = sessionFolders.sorted { a, b in
            if a.url.lastPathComponent == preservingSessionID { return false }
            if b.url.lastPathComponent == preservingSessionID { return true }
            return a.date < b.date
        }

        for folder in sorted {
            guard totalBytes > maxSizeBytes else { break }
            if folder.url.lastPathComponent == preservingSessionID { continue }
            try? FileManager.default.removeItem(at: folder.url)
            totalBytes -= folder.size
        }
    }

    func setMaxCacheSizeBytes(_ bytes: Int64) {
        maxCacheSizeBytes = max(100 * 1024 * 1024, bytes)
        enforceSlidingWindow(playheadOffset: -1)
    }

    func purge() {
        cachedChunkIndices.removeAll()
        chunkAccessOrder.removeAll()
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    /// Returns a list of contiguous cached byte ranges for timeline visualization.
    func contiguousCachedByteRanges() -> [Range<Int64>] {
        let sorted = cachedChunkIndices.sorted()
        guard !sorted.isEmpty else { return [] }

        var ranges: [Range<Int64>] = []
        var currentRange: Range<Int64>? = nil

        for index in sorted {
            let chunkR = byteRange(forChunk: index)
            if let active = currentRange {
                if active.upperBound == chunkR.lowerBound {
                    currentRange = active.lowerBound..<chunkR.upperBound
                } else {
                    ranges.append(active)
                    currentRange = chunkR
                }
            } else {
                currentRange = chunkR
            }
        }
        if let active = currentRange { ranges.append(active) }
        return ranges
    }
}
