import Foundation
import Network
import OSLog

/// Local HTTP loopback proxy providing a 3-tier hybrid disk cache (Demand, Forward Fill, Archive) for video playback.
actor PlaybackStreamCacheServer {
    private let remoteURL: URL
    private let customHeaders: [String: String]
    private let diskCache: PlaybackStreamDiskCache
    private let urlSession: URLSession

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "nuvio.stream.cache.server")
    private var acceptTask: Task<Void, Never>?
    private var forwardFillTask: Task<Void, Never>?
    private var archiveTask: Task<Void, Never>?
    private var inFlightFetches: [Int: Task<Bool, Never>] = [:]

    private(set) var port: UInt16 = 0
    nonisolated let token: String
    nonisolated var path: String { "/stream/\(token)" }
    var localURL: URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    // MARK: - Playhead & Prefetch Tuning

    private var currentPlayheadOffset: Int64 = 0
    /// Target lead ahead of playhead: ~10 minutes of video. For typical 4K/1080p (20–40 Mbps), 150–300 MB is ~10 min.
    private let forwardLeadBytes: Int64 = 250 * 1024 * 1024
    /// Concurrency throttle and rate-limit backoff state
    private var maxConcurrentUpstream = 3
    private var isThrottled = false
    private var lastThrottleTime: Date?
    private let throttleRecoveryInterval: TimeInterval = 300 // 5 minutes

    init(
        remoteURL: URL,
        fileLength: Int64,
        customHeaders: [String: String] = [:],
        sessionID: String = UUID().uuidString,
        maxDiskCacheSizeBytes: Int64 = 20 * 1024 * 1024 * 1024
    ) {
        self.remoteURL = remoteURL
        self.customHeaders = customHeaders
        self.token = sessionID
        self.diskCache = PlaybackStreamDiskCache(
            sessionID: sessionID,
            fileLength: fileLength,
            maxCacheSizeBytes: maxDiskCacheSizeBytes
        )

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 6
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Server Lifecycle

    func start() async throws -> URL {
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
        acceptTask?.cancel()
        acceptTask = nil
        forwardFillTask?.cancel()
        forwardFillTask = nil
        archiveTask?.cancel()
        archiveTask = nil
        inFlightFetches.values.forEach { $0.cancel() }
        inFlightFetches.removeAll()
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
        checkThrottleRecovery()
        let playhead = currentPlayheadOffset
        let totalLen = diskCache.fileLength
        guard totalLen > 0 else { return false }

        let leadAhead = await diskCache.contiguousCachedBytesAhead(of: playhead)
        let isUrgent = leadAhead < forwardLeadBytes

        let startChunk = diskCache.chunkIndex(forByteOffset: playhead)
        let endOffset = min(playhead + forwardLeadBytes, totalLen - 1)
        let endChunk = diskCache.chunkIndex(forByteOffset: endOffset)

        guard endChunk >= startChunk else { return false }
        for chunk in startChunk...endChunk {
            if Task.isCancelled { return false }
            let isCached = await diskCache.isChunkCached(chunk)
            if !isCached {
                await fetchAndCacheChunk(chunk)
                return isUrgent
            }
        }
        return false
    }

    /// Returns `true` if an archive chunk was fetched, or `false` if yielding/paused.
    @discardableResult
    private func performArchiveStep() async -> Bool {
        guard !isThrottled else { return false }
        let total = diskCache.totalChunks
        guard total > 0 else { return false }

        // Protect Tier 2: Only archive if Forward Fill already has at least 80 MB (~3-4 min of 4K) ahead of playhead
        let leadAhead = await diskCache.contiguousCachedBytesAhead(of: currentPlayheadOffset)
        guard leadAhead >= 80 * 1024 * 1024 else {
            return false // Yield bandwidth completely to Forward Fill
        }

        // Fill missing chunks sequentially from start
        for chunk in 0..<total {
            if Task.isCancelled { return false }
            let isCached = await diskCache.isChunkCached(chunk)
            if !isCached {
                await fetchAndCacheChunk(chunk)
                return true
            }
        }
        return false
    }

    // MARK: - Upstream Fetching & Rate Limit Handling

    @discardableResult
    private func fetchAndCacheChunk(_ index: Int) async -> Bool {
        if await diskCache.isChunkCached(index) { return true }

        if let existing = inFlightFetches[index] {
            return await existing.value
        }

        let task = Task<Bool, Never> { [weak self, remoteURL, customHeaders] in
            guard let self else { return false }
            let chunkRange = self.diskCache.byteRange(forChunk: index)
            guard !chunkRange.isEmpty else { return false }

            var req = URLRequest(url: remoteURL)
            req.httpMethod = "GET"
            req.setValue("bytes=\(chunkRange.lowerBound)-\(chunkRange.upperBound - 1)", forHTTPHeaderField: "Range")
            for (k, v) in customHeaders { req.setValue(v, forHTTPHeaderField: k) }

            for attempt in 1...3 {
                if Task.isCancelled { return false }
                do {
                    let (data, response) = try await self.urlSession.data(for: req)
                    if let http = response as? HTTPURLResponse {
                        if http.statusCode == 429 || http.statusCode == 503 {
                            await self.applyRateLimitThrottle()
                            return false
                        }
                        guard http.statusCode == 200 || http.statusCode == 206 else {
                            try? await Task.sleep(nanoseconds: 100_000_000 * UInt64(attempt))
                            continue
                        }
                    }
                    guard !data.isEmpty else { continue }
                    let playhead = await self.currentPlayheadOffset
                    await self.diskCache.writeChunk(index, data: data, playheadOffset: playhead)
                    return true
                } catch {
                    if attempt == 3 {
                        diskCacheLog.warning("Upstream chunk \(index) fetch failed after 3 attempts: \(error.localizedDescription)")
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000 * UInt64(attempt))
                }
            }
            return false
        }

        inFlightFetches[index] = task
        let result = await task.value
        inFlightFetches.removeValue(forKey: index)
        return result
    }

    private func applyRateLimitThrottle() {
        isThrottled = true
        maxConcurrentUpstream = max(1, maxConcurrentUpstream - 1)
        lastThrottleTime = Date()
        diskCacheLog.warning("Provider rate limit detected. Concurrency lowered to \(self.maxConcurrentUpstream)")
    }

    private func checkThrottleRecovery() {
        guard isThrottled, let last = lastThrottleTime else { return }
        if Date().timeIntervalSince(last) >= throttleRecoveryInterval {
            isThrottled = false
            maxConcurrentUpstream = 3
            diskCacheLog.notice("Rate limit recovery period elapsed. Concurrency restored to 3.")
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
                    let specs = rangeVal.dropFirst("bytes=".count).split(separator: "-")
                    if let firstStr = specs.first, let start = Int64(firstStr) {
                        requestedStart = start
                    }
                    if specs.count > 1, let secondStr = specs.last, let end = Int64(secondStr) {
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

        currentPlayheadOffset = requestedStart
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
                // Not in cache: demand fetch chunk immediately
                let success = await fetchAndCacheChunk(chunkIdx)
                if success {
                    data = await diskCache.readBytes(offset: currentOffset, length: bytesToRead)
                }
            }

            guard let bytesToSend = data, !bytesToSend.isEmpty else {
                diskCacheLog.error("Demand fetch failed for offset \(currentOffset) in chunk \(chunkIdx). Aborting range response.")
                break
            }
            try await NetworkIO.send(connection, bytesToSend)
            currentOffset += Int64(bytesToSend.count)
        }

        return false
    }

    // MARK: - Telemetry & Ranges

    func cachedByteRanges() async -> [Range<Int64>] {
        await diskCache.contiguousCachedByteRanges()
    }

    func cachedFraction() async -> Double {
        await diskCache.cachedFraction
    }
}
