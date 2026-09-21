import Foundation
import Network
import OSLog

/// Local HTTP loopback proxy providing a 3-tier hybrid disk cache (Demand, Forward Fill, Archive) for video playback.
actor PlaybackStreamCacheServer {
    private enum FetchPriority: Sendable { case demand, forward, archive }
    private let remoteURL: URL
    private let customHeaders: [String: String]
    private let diskCache: PlaybackStreamDiskCache
    private let urlSession: URLSession

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "nuvio.stream.cache.server")
    private var acceptTask: Task<Void, Never>?
    private var forwardFillTask: Task<Void, Never>?
    private var archiveTask: Task<Void, Never>?
    private var inFlightBatchFetches: [Int: (id: UUID, priority: FetchPriority, task: Task<[Int: Data]?, Never>)] = [:]
    private var inFlightDemandFetches: [Int: Task<Data?, Never>] = [:]
    private var diskWriteFailed = false
    private var stopped = false
    private var activeUpstreamFetches = 0
    private var queuedDemandWaiters = 0
    private var activeDemandFetches = 0
    var hasActiveDemand: Bool { queuedDemandWaiters > 0 || activeDemandFetches > 0 }
    private var throttleUntil: Date?
    private let rateLimitCooldown: TimeInterval

    private(set) var port: UInt16 = 0
    nonisolated let token: String
    nonisolated var path: String { "/stream/\(token)" }
    var localURL: URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    // MARK: - Playhead & Prefetch Tuning

    /// Player playback position reported from UI/media player timeline polling.
    private var playerPlayheadOffset: Int64 = 0
    /// Active download offset read by the local HTTP client/socket.
    private var clientReadOffset: Int64 = 0
    /// Furthest actively consumed position; forward fill anchors here to prevent downloading behind active reads.
    private var effectiveAnchorOffset: Int64 {
        max(playerPlayheadOffset, clientReadOffset)
    }
    private var durationSeconds: Double?
    private var lastMeasuredBps: Double?
    private let targetLeadSeconds: Double = 150.0 // 2.5 minutes ahead of playhead
    private let minForwardLeadBytes: Int64 = 80 * 1024 * 1024 // 80 MB minimum
    private let maxForwardLeadBytes: Int64 = 1500 * 1024 * 1024 // 1.5 GB maximum
    static let maxBatchChunks = 4 // Batch up to 4 chunks (8 MiB) per sequential upstream request

    /// Adaptive forward buffer lead calculated from video duration and file length.
    var adaptiveForwardLeadBytes: Int64 {
        let totalLen = diskCache.fileLength
        if let dur = durationSeconds, dur > 0, totalLen > 0 {
            let estimatedByteRate = Double(totalLen) / dur
            let targetBytes = Int64(estimatedByteRate * targetLeadSeconds)
            return min(maxForwardLeadBytes, max(minForwardLeadBytes, targetBytes))
        }
        return 250 * 1024 * 1024
    }

    func updateTimeline(playheadOffset: Int64, durationSeconds: Double? = nil, isSeek: Bool = false) {
        if let durationSeconds, durationSeconds > 0 {
            self.durationSeconds = durationSeconds
        }
        if isSeek {
            cancelObsoletePrefetch()
            // Re-anchor both timeline observers so an explicit seek does not retain
            // the old forward read position as the active prefetch anchor.
            clientReadOffset = playheadOffset
        }
        playerPlayheadOffset = playheadOffset
    }

    private func handleClientReadJump(newOffset: Int64) {
        let diffFromClient = abs(newOffset - clientReadOffset)
        let diffFromPlayer = abs(newOffset - playerPlayheadOffset)
        let seekThreshold: Int64 = 8 * 1024 * 1024 // 8 MiB (4 chunks)
        // If HTTP read jumps away from both current client read and player playhead, cancel obsolete prefetch
        if diffFromClient > seekThreshold && diffFromPlayer > seekThreshold {
            cancelObsoletePrefetch()
        }
        clientReadOffset = newOffset
    }

    private func cancelObsoletePrefetch() {
        var toCancel: [UUID: Task<[Int: Data]?, Never>] = [:]
        for (_, entry) in inFlightBatchFetches {
            if entry.priority == .forward || entry.priority == .archive {
                toCancel[entry.id] = entry.task
            }
        }
        for (_, task) in toCancel {
            task.cancel()
        }
    }

    private func updateThroughput(_ byteRate: Double) {
        guard byteRate > 0 else { return }
        if let current = lastMeasuredBps {
            lastMeasuredBps = current * 0.7 + byteRate * 0.3
        } else {
            lastMeasuredBps = byteRate
        }
    }

    /// Concurrency throttle and rate-limit backoff state
    private var maxConcurrentUpstream = 3
    private let configuredMaxConcurrentUpstream: Int
    private var isThrottled = false
    private var lastThrottleTime: Date?
    private let throttleRecoveryInterval: TimeInterval = 300 // 5 minutes

    init(
        remoteURL: URL,
        fileLength: Int64,
        customHeaders: [String: String] = [:],
        sessionID: String = UUID().uuidString,
        maxDiskCacheSizeBytes: Int64 = 20 * 1024 * 1024 * 1024,
        freeSpaceReserveBytes: Int64 = PlaybackStreamDiskCache.defaultFreeSpaceReserveBytes,
        cacheRoot: URL? = nil,
        manifest: PlaybackStreamManifest? = nil,
        sessionConfiguration: URLSessionConfiguration? = nil,
        rateLimitCooldown: TimeInterval = 1,
        maxConcurrentUpstream: Int = 3,
        freeSpaceProvider: PlaybackStreamDiskCache.FreeSpaceProvider? = nil
    ) {
        self.remoteURL = remoteURL
        self.customHeaders = customHeaders
        self.token = sessionID
        self.rateLimitCooldown = rateLimitCooldown.isFinite ? min(max(0.1, rateLimitCooldown), 60) : 1
        self.configuredMaxConcurrentUpstream = max(1, maxConcurrentUpstream)
        self.maxConcurrentUpstream = self.configuredMaxConcurrentUpstream
        self.diskCache = PlaybackStreamDiskCache(
            sessionID: sessionID,
            fileLength: fileLength,
            maxCacheSizeBytes: maxDiskCacheSizeBytes,
            freeSpaceReserveBytes: freeSpaceReserveBytes,
            cacheRoot: cacheRoot,
            manifest: manifest,
            freeSpaceProvider: freeSpaceProvider
        )

        let config = sessionConfiguration ?? URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 6
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Server Lifecycle

    func start() async throws -> URL {
        stopped = false
        if let listener, listener.state == .ready { return localURL }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = false
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: .any
        )
        let listener = try NWListener(using: params)

        let incoming = AsyncStream<NWConnection> { continuation in
            listener.newConnectionHandler = { continuation.yield($0) }
            continuation.onTermination = { _ in listener.cancel() }
        }

        let bound = await Self.bind(listener, on: queue)

        guard bound, let actualPort = listener.port?.rawValue else {
            throw TorrentEngineError.failedToStart
        }
        self.listener = listener
        self.port = actualPort
        diskCacheLog.notice("PlaybackStreamCacheServer started on 127.0.0.1:\(actualPort)")

        acceptTask = Task { await self.acceptLoop(incoming) }
        startBackgroundWorkers()
        return localURL
    }

    private nonisolated static func bind(_ listener: NWListener, on queue: DispatchQueue) async -> Bool {
        let gate = OnceGate<Bool>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.arm(continuation)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        listener.stateUpdateHandler = nil
                        gate.resume(true)
                    case .failed, .cancelled:
                        listener.stateUpdateHandler = nil
                        gate.resume(false)
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 3) {
                    listener.stateUpdateHandler = nil
                    gate.resume(false)
                }
            }
        } onCancel: {
            listener.stateUpdateHandler = nil
            listener.cancel()
            gate.resume(false)
        }
    }

    func stop() {
        stopped = true
        acceptTask?.cancel()
        acceptTask = nil
        forwardFillTask?.cancel()
        forwardFillTask = nil
        archiveTask?.cancel()
        archiveTask = nil
        inFlightBatchFetches.values.forEach { $0.task.cancel() }
        inFlightBatchFetches.removeAll()
        inFlightDemandFetches.values.forEach { $0.cancel() }
        inFlightDemandFetches.removeAll()
        activeUpstreamFetches = 0
        activeDemandFetches = 0
        queuedDemandWaiters = 0
        listener?.cancel()
        listener = nil
        urlSession.invalidateAndCancel()
    }

    // MARK: - Background Workers (Tier 2 & Tier 3)

    private func startBackgroundWorkers() {
        // Tier 2: Forward Fill (~10 minutes ahead of playhead)
        forwardFillTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let isUrgent = await self.performForwardFillStep()
                if isUrgent {
                    // Low lead ahead: burst fill without artificial sleep delay
                    await Task.yield()
                } else {
                    // Target lead satisfied: rest before polling playhead progress
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }

        // Tier 3: Archive (Fills whole title from 0 to end in background)
        archiveTask = Task(priority: .background) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let didFetch = await self.performArchiveStep()
                if didFetch {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    /// Returns `true` if the buffer ahead is still actively building toward the target lead.
    @discardableResult
    private func performForwardFillStep() async -> Bool {
        guard !diskWriteFailed else { return false }
        guard !hasActiveDemand else { return false }
        checkThrottleRecovery()
        let playhead = effectiveAnchorOffset
        let totalLen = diskCache.fileLength
        guard totalLen > 0 else { return false }

        let leadAhead = await diskCache.contiguousCachedBytesAhead(of: playhead)
        let targetLead = adaptiveForwardLeadBytes
        let isUrgent = leadAhead < targetLead

        let startChunk = diskCache.chunkIndex(forByteOffset: playhead)
        let endOffset = min(playhead + targetLead, totalLen - 1)
        let endChunk = diskCache.chunkIndex(forByteOffset: endOffset)

        guard endChunk >= startChunk else { return false }
        var chunk = startChunk
        while chunk <= endChunk {
            if Task.isCancelled || hasActiveDemand { return false }
            let isCached = await diskCache.isChunkCached(chunk)
            if !isCached && inFlightDemandFetches[chunk] == nil {
                guard await diskCache.canPrefetchChunk(chunk, playheadOffset: playhead, evictBehindPlayhead: true) else {
                    return false
                }
                var batchCount = 1
                while batchCount < Self.maxBatchChunks && (chunk + batchCount) <= endChunk {
                    let next = chunk + batchCount
                    if await diskCache.isChunkCached(next) || inFlightDemandFetches[next] != nil { break }
                    batchCount += 1
                }
                let fetched = await fetchAndCacheBatch(startingAt: chunk, count: batchCount, priority: .forward)
                return isUrgent && fetched != nil
            }
            chunk += 1
        }
        return false
    }

    /// Returns `true` if an archive chunk was fetched, or `false` if yielding/paused.
    @discardableResult
    private func performArchiveStep() async -> Bool {
        guard !diskWriteFailed else { return false }
        guard !isThrottled else { return false }
        guard !hasActiveDemand else {
            // Priority scheduling: player demand takes complete priority over archive
            return false
        }
        let total = diskCache.totalChunks
        guard total > 0 else { return false }

        // Protect Tier 2: Only archive if Forward Fill already has at least 80% of target lead
        let playhead = effectiveAnchorOffset
        let leadAhead = await diskCache.contiguousCachedBytesAhead(of: playhead)
        let neededLead = adaptiveForwardLeadBytes
        guard leadAhead >= Int64(Double(neededLead) * 0.8) else {
            return false // Yield bandwidth completely to Forward Fill
        }

        let startChunk = diskCache.chunkIndex(forByteOffset: playhead)
        guard startChunk < total else { return false }
        var chunk = startChunk
        while chunk < total {
            if Task.isCancelled || hasActiveDemand { return false }
            let isCached = await diskCache.isChunkCached(chunk)
            if !isCached,
               await diskCache.canPrefetchChunk(chunk, playheadOffset: playhead, evictBehindPlayhead: false) {
                var batchCount = 1
                while batchCount < Self.maxBatchChunks && (chunk + batchCount) < total {
                    let next = chunk + batchCount
                    if await diskCache.isChunkCached(next) { break }
                    batchCount += 1
                }
                let fetched = await fetchAndCacheBatch(startingAt: chunk, count: batchCount, priority: .archive)
                return fetched != nil
            }
            chunk += 1
        }
        return false
    }

    // MARK: - Prompt Demand Fetching (Tier 1)

    /// Prompt single-chunk fetch path dedicated to real-time player demand with minimal TTFB.
    /// Does not block on background batch fetches, and delivers data in RAM even if disk headroom is full.
    @discardableResult
    func fetchDemandChunk(_ index: Int) async -> Data? {
        if let cached = await diskCache.readChunk(index) { return cached }
        if let existing = inFlightDemandFetches[index] {
            return await existing.value
        }
        let total = diskCache.totalChunks
        guard index >= 0, index < total else { return nil }

        let task = Task<Data?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.executeDemandFetch(index)
        }
        inFlightDemandFetches[index] = task
        let result = await task.value
        inFlightDemandFetches.removeValue(forKey: index)
        return result
    }

    private func executeDemandFetch(_ index: Int) async -> Data? {
        let chunkRange = diskCache.byteRange(forChunk: index)
        var req = URLRequest(url: remoteURL)
        req.httpMethod = "GET"
        for (k, v) in customHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("bytes=\(chunkRange.lowerBound)-\(chunkRange.upperBound - 1)", forHTTPHeaderField: "Range")

        for attempt in 1...3 {
            if Task.isCancelled { return nil }
            guard await acquireFetchSlot(priority: .demand) else { return nil }

            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                let (data, response) = try await urlSession.data(for: req)
                guard !Task.isCancelled else {
                    releaseFetchSlot(priority: .demand)
                    return nil
                }
                let elapsed = CFAbsoluteTimeGetCurrent() - t0
                if elapsed > 0.05, !data.isEmpty {
                    updateThroughput(Double(data.count) / elapsed)
                }

                let retryDelay = finishFetch(response: response as? HTTPURLResponse, priority: .demand)
                guard let http = response as? HTTPURLResponse else { continue }
                if let delay = retryDelay {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                guard http.statusCode == 206,
                      Self.responseMatches(range: chunkRange, response: http, bodyCount: data.count,
                                           expectedFileLength: diskCache.fileLength) else {
                    try? await Task.sleep(nanoseconds: 100_000_000 * UInt64(attempt))
                    continue
                }
                guard !data.isEmpty, !Task.isCancelled else { continue }

                if shouldPersistToDisk() {
                    let playhead = effectiveAnchorOffset
                    let persisted = await diskCache.writeChunk(index, data: data, playheadOffset: playhead)
                    if !persisted { markDiskWriteFailed() }
                }
                // Return data even if disk headroom was exhausted so playback continues in RAM
                return data
            } catch {
                releaseFetchSlot(priority: .demand)
                if attempt == 3 {
                    diskCacheLog.warning("Upstream demand fetch for chunk \(index) failed after 3 attempts: \(error.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: 100_000_000 * UInt64(attempt))
            }
        }
        return nil
    }

    // MARK: - Background Batch Fetching (Tier 2 & Tier 3)

    @discardableResult
    private func fetchAndCacheBatch(
        startingAt startChunk: Int, count: Int, priority: FetchPriority
    ) async -> [Int: Data]? {
        let total = diskCache.totalChunks
        guard startChunk >= 0, startChunk < total, count > 0 else { return nil }
        let actualCount = min(count, total - startChunk)

        // Single chunk fast-path if already cached
        if actualCount == 1, let cached = await diskCache.readChunk(startChunk) {
            return [startChunk: cached]
        }

        if let existing = inFlightBatchFetches[startChunk] {
            return await existing.task.value
        }

        let startByte = diskCache.byteRange(forChunk: startChunk).lowerBound
        let endByte = diskCache.byteRange(forChunk: startChunk + actualCount - 1).upperBound
        let batchRange = startByte..<endByte
        guard !batchRange.isEmpty else { return nil }

        let fetchID = UUID()
        let task = Task<[Int: Data]?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.executeBatchFetch(
                startingAt: startChunk, actualCount: actualCount, priority: priority, batchRange: batchRange
            )
        }

        for i in 0..<actualCount {
            inFlightBatchFetches[startChunk + i] = (fetchID, priority, task)
        }
        let result = await task.value
        for i in 0..<actualCount {
            if inFlightBatchFetches[startChunk + i]?.id == fetchID {
                inFlightBatchFetches.removeValue(forKey: startChunk + i)
            }
        }
        return result
    }

    private func executeBatchFetch(
        startingAt startChunk: Int, actualCount: Int, priority: FetchPriority, batchRange: Range<Int64>
    ) async -> [Int: Data]? {
        var req = URLRequest(url: remoteURL)
        req.httpMethod = "GET"
        for (k, v) in customHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("bytes=\(batchRange.lowerBound)-\(batchRange.upperBound - 1)", forHTTPHeaderField: "Range")

        for attempt in 1...3 {
            if Task.isCancelled { return nil }
            guard await acquireFetchSlot(priority: priority) else { return nil }

            let admissionPlayhead = effectiveAnchorOffset
            if priority == .forward,
               !(await diskCache.canPrefetchChunk(startChunk, playheadOffset: admissionPlayhead, evictBehindPlayhead: true)) {
                releaseFetchSlot(priority: priority)
                return nil
            }
            if priority == .archive,
               !(await diskCache.canPrefetchChunk(startChunk, playheadOffset: admissionPlayhead, evictBehindPlayhead: false)) {
                releaseFetchSlot(priority: priority)
                return nil
            }

            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                let (data, response) = try await urlSession.data(for: req)
                guard !Task.isCancelled else {
                    releaseFetchSlot(priority: priority)
                    return nil
                }
                let elapsed = CFAbsoluteTimeGetCurrent() - t0
                if elapsed > 0.05, !data.isEmpty {
                    updateThroughput(Double(data.count) / elapsed)
                }

                let retryDelay = finishFetch(response: response as? HTTPURLResponse, priority: priority)
                guard let http = response as? HTTPURLResponse else { continue }
                if let delay = retryDelay {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                guard http.statusCode == 206,
                      Self.responseMatches(range: batchRange, response: http, bodyCount: data.count,
                                           expectedFileLength: diskCache.fileLength) else {
                    try? await Task.sleep(nanoseconds: 100_000_000 * UInt64(attempt))
                    continue
                }
                guard !data.isEmpty, !Task.isCancelled else { continue }

                var resultMap: [Int: Data] = [:]
                var offset = 0
                for i in 0..<actualCount {
                    guard !Task.isCancelled else { return nil }
                    let c = startChunk + i
                    let cRange = diskCache.byteRange(forChunk: c)
                    let cLen = Int(cRange.count)
                    guard offset + cLen <= data.count else {
                        // Truncated/partial response: stop committing further chunks
                        break
                    }
                    let chunkBytes = Data(data[offset..<(offset + cLen)])
                    offset += cLen
                    resultMap[c] = chunkBytes

                    if shouldPersistToDisk() {
                        guard !Task.isCancelled else { return nil }
                        let playhead = effectiveAnchorOffset
                        let persisted = await diskCache.writeChunk(
                            c, data: chunkBytes, playheadOffset: playhead,
                            prefetchEvictsBehind: priority == .forward
                        )
                        if !persisted { markDiskWriteFailed() }
                    }
                }
                guard !Task.isCancelled else { return nil }
                return resultMap
            } catch {
                releaseFetchSlot(priority: priority)
                if attempt == 3 {
                    diskCacheLog.warning("Upstream batch fetch [\(startChunk)..<(\(startChunk + actualCount))] failed after 3 attempts: \(error.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: 100_000_000 * UInt64(attempt))
            }
        }
        return nil
    }

    // MARK: - Upstream Concurrency & Priority Scheduling

    private func preemptBackgroundTasksForDemand() {
        var archiveTasks: [UUID: Task<[Int: Data]?, Never>] = [:]
        var forwardTasks: [UUID: Task<[Int: Data]?, Never>] = [:]
        for (_, entry) in inFlightBatchFetches {
            if entry.priority == .archive {
                archiveTasks[entry.id] = entry.task
            } else if entry.priority == .forward {
                forwardTasks[entry.id] = entry.task
            }
        }
        // First cancel low-priority archive tasks
        if !archiveTasks.isEmpty {
            for (_, task) in archiveTasks { task.cancel() }
        } else if !forwardTasks.isEmpty {
            // When concurrency is saturated (e.g. maxConcurrentUpstream = 1),
            // preempt in-flight forward batch so real-time playback demand is never blocked.
            for (_, task) in forwardTasks { task.cancel() }
        }
    }

    private func acquireFetchSlot(priority: FetchPriority) async -> Bool {
        var queuedDemand = false
        if priority == .demand {
            queuedDemandWaiters += 1
            queuedDemand = true
            if activeUpstreamFetches >= maxConcurrentUpstream {
                preemptBackgroundTasksForDemand()
            }
        }
        defer {
            if queuedDemand {
                queuedDemandWaiters -= 1
            }
        }

        while !Task.isCancelled && !stopped {
            checkThrottleRecovery()
            let coolingDown = throttleUntil.map { $0 > Date() } ?? false
            let isDemand = priority == .demand
            if isDemand && !queuedDemand {
                queuedDemandWaiters += 1
                queuedDemand = true
                if activeUpstreamFetches >= maxConcurrentUpstream {
                    preemptBackgroundTasksForDemand()
                }
            }
            let canEnter = isDemand || !hasActiveDemand
            if !coolingDown && canEnter && activeUpstreamFetches < maxConcurrentUpstream {
                activeUpstreamFetches += 1
                if isDemand {
                    activeDemandFetches += 1
                }
                return true
            }
            do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return false }
        }
        return false
    }

    private func releaseFetchSlot(priority: FetchPriority) {
        if priority == .demand {
            activeDemandFetches = max(0, activeDemandFetches - 1)
        }
        activeUpstreamFetches = max(0, activeUpstreamFetches - 1)
    }

    private func finishFetch(response: HTTPURLResponse?, priority: FetchPriority) -> TimeInterval? {
        let delay: TimeInterval?
        if let response, response.statusCode == 429 || response.statusCode == 503 {
            delay = applyRateLimitThrottle(response: response)
        } else {
            delay = nil
        }
        releaseFetchSlot(priority: priority)
        return delay
    }

    private func releaseFetchSlot() {
        activeUpstreamFetches = max(0, activeUpstreamFetches - 1)
    }

    private func markDiskWriteFailed() {
        diskWriteFailed = true
        diskCacheLog.error("Disabling background cache fills after a disk write failure")
    }

    private func shouldPersistToDisk() -> Bool {
        !diskWriteFailed
    }

    private nonisolated static func responseMatches(
        range: Range<Int64>, response: HTTPURLResponse, bodyCount: Int, expectedFileLength: Int64
    ) -> Bool {
        guard bodyCount == Int(range.count),
              let contentRange = response.value(forHTTPHeaderField: "Content-Range") else { return false }
        let parts = contentRange.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "/" })
        guard parts.count == 4, parts[0].lowercased() == "bytes",
              let start = Int64(parts[1]), let end = Int64(parts[2]) else { return false }
        let totalMatches = parts[3] == "*" || Int64(parts[3]) == expectedFileLength
        return start == range.lowerBound && end == range.upperBound - 1 && totalMatches
    }

    private func applyRateLimitThrottle(response: HTTPURLResponse) -> TimeInterval {
        isThrottled = true
        maxConcurrentUpstream = max(1, maxConcurrentUpstream - 1)
        lastThrottleTime = Date()
        let parsedDelay = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        let retryAfter = parsedDelay.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? rateLimitCooldown
        let delay = min(max(0.1, retryAfter), 60)
        let newUntil = Date().addingTimeInterval(delay)
        throttleUntil = max(throttleUntil ?? .distantPast, newUntil)
        diskCacheLog.warning("Provider rate limit detected. Concurrency lowered to \(self.maxConcurrentUpstream)")
        return delay
    }

    private func checkThrottleRecovery() {
        guard isThrottled, let last = lastThrottleTime else { return }
        if Date().timeIntervalSince(last) >= throttleRecoveryInterval {
            isThrottled = false
            maxConcurrentUpstream = configuredMaxConcurrentUpstream
            diskCacheLog.notice("Rate limit recovery period elapsed. Concurrency restored to \(self.maxConcurrentUpstream).")
        }
    }

    // MARK: - Client Request Handling (Tier 1 Demand)

    private func acceptLoop(_ incoming: AsyncStream<NWConnection>) async {
        await withDiscardingTaskGroup { group in
            for await connection in incoming {
                group.addTask { await self.serve(connection) }
            }
        }
    }

    private func serve(_ connection: NWConnection) async {
        defer { connection.cancel() }
        var buffer = Data()
        do {
            try await NetworkIO.start(connection, on: queue)
            while !Task.isCancelled {
                let (head, rest) = try await readRequestHead(connection, buffer: buffer)
                buffer = rest
                guard try await respond(to: head, on: connection) else { return }
            }
        } catch {}
    }

    private func readRequestHead(_ connection: NWConnection, buffer: Data) async throws -> (head: String, rest: Data) {
        var buffer = buffer
        let terminator = Data("\r\n\r\n".utf8)
        while true {
            if let end = buffer.range(of: terminator) {
                let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) ?? ""
                return (head, Data(buffer[end.upperBound...]))
            }
            guard buffer.count < 64 * 1024 else { throw NetworkIO.Failure.closed }
            buffer.append(try await NetworkIO.receive(connection, atMost: 8192))
        }
    }

    private func respond(to request: String, on connection: NWConnection) async throws -> Bool {
        let lines = request.components(separatedBy: "\r\n")
        guard let first = lines.first else { return false }
        let requestParts = first.components(separatedBy: " ")
        let method = requestParts.first ?? "GET"

        let fileLength = diskCache.fileLength

        // Parse Range Header
        var requestedStart: Int64 = 0
        var requestedEnd: Int64 = fileLength - 1
        var isRangeRequest = false

        for line in lines {
            if line.lowercased().hasPrefix("range:") {
                isRangeRequest = true
                let rangeVal = line.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
                if rangeVal.hasPrefix("bytes=") {
                    let spec = rangeVal.dropFirst("bytes=".count)
                    let specs = spec.split(separator: "-", omittingEmptySubsequences: false)
                    // A leading "-" is a suffix range: the final N bytes (RFC 9110 §14.1.2).
                    let suffix = spec.hasPrefix("-") ? Int64(spec.dropFirst()) : nil
                    if let suffix {
                        requestedStart = max(0, fileLength - suffix)
                    } else if let firstStr = specs.first, let start = Int64(firstStr) {
                        requestedStart = start
                    }
                    if suffix == nil, specs.count > 1, let secondStr = specs.last, !secondStr.isEmpty, let end = Int64(secondStr) {
                        requestedEnd = end
                    }
                }
            }
        }

        requestedEnd = min(requestedEnd, fileLength - 1)
        guard requestedStart <= requestedEnd else {
            let errorResponse = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(fileLength)\r\n\r\n"
            try await NetworkIO.send(connection, Data(errorResponse.utf8))
            return false
        }

        handleClientReadJump(newOffset: requestedStart)
        let responseLength = requestedEnd - requestedStart + 1

        var headers = isRangeRequest ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        headers += "Content-Type: video/mp4\r\n"
        headers += "Accept-Ranges: bytes\r\n"
        headers += "Content-Length: \(responseLength)\r\n"
        if isRangeRequest {
            headers += "Content-Range: bytes \(requestedStart)-\(requestedEnd)/\(fileLength)\r\n"
        }
        headers += "Connection: close\r\n\r\n"

        try await NetworkIO.send(connection, Data(headers.utf8))
        if method == "HEAD" { return false }

        // Stream range to client using Demand Priority, clamped to chunk boundaries
        var currentOffset = requestedStart
        while currentOffset <= requestedEnd && !Task.isCancelled {
            let chunkIdx = diskCache.chunkIndex(forByteOffset: currentOffset)
            let chunkRange = diskCache.byteRange(forChunk: chunkIdx)
            let maxInCurrentChunk = Int(chunkRange.upperBound - currentOffset)
            guard maxInCurrentChunk > 0 else { break }
            let bytesToRead = min(maxInCurrentChunk, Int(requestedEnd - currentOffset + 1))

            var data = await diskCache.readBytes(offset: currentOffset, length: bytesToRead)
            if data == nil {
                // Not in cache: demand fetch chunk immediately (prompt independent demand fetch)
                if let fetched = await fetchDemandChunk(chunkIdx) {
                    let sliceStart = Int(currentOffset - chunkRange.lowerBound)
                    let sliceEnd = sliceStart + bytesToRead
                    if sliceStart >= 0, sliceEnd <= fetched.count {
                        data = Data(fetched[sliceStart..<sliceEnd])
                    }
                }
            }

            guard let bytesToSend = data, !bytesToSend.isEmpty else {
                diskCacheLog.error("Demand fetch failed for offset \(currentOffset) in chunk \(chunkIdx). Aborting range response.")
                break
            }
            try await NetworkIO.send(connection, bytesToSend)
            currentOffset += Int64(bytesToSend.count)
            clientReadOffset = currentOffset
        }

        return false
    }

    // MARK: - Telemetry & Ranges

    var fileLength: Int64 {
        diskCache.fileLength
    }

    func contiguousCachedBytesAhead(of byteOffset: Int64) async -> Int64 {
        await diskCache.contiguousCachedBytesAhead(of: byteOffset)
    }

    func cachedByteRanges() async -> [Range<Int64>] {
        await diskCache.contiguousCachedByteRanges()
    }

    func cachedFraction() async -> Double {
        await diskCache.cachedFraction
    }
}
