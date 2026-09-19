import XCTest
@testable import NuvioTV

final class PlaybackStreamCacheTests: XCTestCase {

    func testChunkIndexAndByteRangeCalculations() async {
        let fileLength: Int64 = 10 * 1024 * 1024 // 10 MiB
        let chunkSize: Int64 = 2 * 1024 * 1024 // 2 MiB
        let cache = PlaybackStreamDiskCache(
            sessionID: "test_session_math_\(UUID().uuidString)",
            fileLength: fileLength,
            chunkSize: chunkSize
        )

        let total = cache.totalChunks
        XCTAssertEqual(total, 5)

        let chunk0Index = cache.chunkIndex(forByteOffset: 0)
        let chunk0Range = cache.byteRange(forChunk: 0)
        XCTAssertEqual(chunk0Index, 0)
        XCTAssertEqual(chunk0Range, 0..<(2 * 1024 * 1024))

        let chunk2Index = cache.chunkIndex(forByteOffset: 4 * 1024 * 1024 + 500)
        let chunk2Range = cache.byteRange(forChunk: 2)
        XCTAssertEqual(chunk2Index, 2)
        XCTAssertEqual(chunk2Range, (4 * 1024 * 1024)..<(6 * 1024 * 1024))

        let lastChunkIndex = cache.chunkIndex(forByteOffset: fileLength - 1)
        let lastChunkRange = cache.byteRange(forChunk: 4)
        XCTAssertEqual(lastChunkIndex, 4)
        XCTAssertEqual(lastChunkRange, (8 * 1024 * 1024)..<(10 * 1024 * 1024))

        await cache.purge()
    }

    func testWriteAndReadChunkData() async {
        let fileLength: Int64 = 6 * 1024 * 1024
        let chunkSize: Int64 = 2 * 1024 * 1024
        let session = "test_write_read_\(UUID().uuidString)"
        let cache = PlaybackStreamDiskCache(
            sessionID: session,
            fileLength: fileLength,
            chunkSize: chunkSize
        )

        let sampleChunkData = Data(repeating: 0xAB, count: Int(chunkSize))
        await cache.writeChunk(0, data: sampleChunkData)

        let isCached = await cache.isChunkCached(0)
        XCTAssertTrue(isCached)

        let readBack = await cache.readChunk(0)
        XCTAssertEqual(readBack, sampleChunkData)

        // Read bytes across partial range
        let partial = await cache.readBytes(offset: 100, length: 50)
        XCTAssertNotNil(partial)
        XCTAssertEqual(partial?.count, 50)
        XCTAssertEqual(partial, Data(repeating: 0xAB, count: 50))

        await cache.purge()
    }

    func testSlidingWindowFIFOEviction() async {
        let fileLength: Int64 = 10 * 1024 * 1024 // 10 MiB (5 chunks of 2 MiB)
        let chunkSize: Int64 = 2 * 1024 * 1024
        let maxCacheSize: Int64 = 4 * 1024 * 1024 // Max 2 chunks (4 MiB)
        let session = "test_eviction_\(UUID().uuidString)"
        let cache = PlaybackStreamDiskCache(
            sessionID: session,
            fileLength: fileLength,
            chunkSize: chunkSize,
            maxCacheSizeBytes: maxCacheSize
        )

        let chunkData = Data(repeating: 0x01, count: Int(chunkSize))

        // Write chunk 0 and 1
        await cache.writeChunk(0, data: chunkData, playheadOffset: 0)
        await cache.writeChunk(1, data: chunkData, playheadOffset: 2 * 1024 * 1024)

        var cachedBytes = await cache.currentCachedBytes
        XCTAssertEqual(cachedBytes, 4 * 1024 * 1024)
        let chunk0Cached = await cache.isChunkCached(0)
        let chunk1Cached = await cache.isChunkCached(1)
        XCTAssertTrue(chunk0Cached)
        XCTAssertTrue(chunk1Cached)

        // Advance playhead to chunk 2 and write chunk 2 -> chunk 0 (oldest footage behind playhead) should be evicted
        await cache.writeChunk(2, data: chunkData, playheadOffset: 4 * 1024 * 1024)

        cachedBytes = await cache.currentCachedBytes
        XCTAssertEqual(cachedBytes, 4 * 1024 * 1024)
        let chunk0StillCached = await cache.isChunkCached(0)
        let chunk1StillCached = await cache.isChunkCached(1)
        let chunk2Cached = await cache.isChunkCached(2)
        XCTAssertFalse(chunk0StillCached) // Evicted
        XCTAssertTrue(chunk1StillCached)
        XCTAssertTrue(chunk2Cached)

        await cache.purge()
    }

    func testContiguousCachedRangesVisualization() async {
        let fileLength: Int64 = 10 * 1024 * 1024
        let chunkSize: Int64 = 2 * 1024 * 1024
        let session = "test_ranges_\(UUID().uuidString)"
        let cache = PlaybackStreamDiskCache(
            sessionID: session,
            fileLength: fileLength,
            chunkSize: chunkSize
        )

        let chunkData = Data(repeating: 0x00, count: Int(chunkSize))
        // Write chunk 0, 1 (contiguous 0..<4MB) and chunk 3 (gap at 2, chunk 3 is 6MB..<8MB)
        await cache.writeChunk(0, data: chunkData)
        await cache.writeChunk(1, data: chunkData)
        await cache.writeChunk(3, data: chunkData)

        let ranges = await cache.contiguousCachedByteRanges()
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0], 0..<(4 * 1024 * 1024))
        XCTAssertEqual(ranges[1], (6 * 1024 * 1024)..<(8 * 1024 * 1024))

        await cache.purge()
    }

    func testServerStartLifecycleAndContinuationSafety() async throws {
        let dummyURL = URL(string: "http://127.0.0.1:9999/video.mp4")!
        let server = PlaybackStreamCacheServer(
            remoteURL: dummyURL,
            fileLength: 50 * 1024 * 1024,
            sessionID: "test_server_lifecycle_\(UUID().uuidString)"
        )

        let localURL = try await server.start()
        XCTAssertTrue(localURL.absoluteString.starts(with: "http://127.0.0.1:"))

        // Verify calling start() again returns the same URL gracefully
        let localURL2 = try await server.start()
        XCTAssertEqual(localURL, localURL2)

        try await Task.sleep(nanoseconds: 200_000_000)
        await server.stop()
    }
}

