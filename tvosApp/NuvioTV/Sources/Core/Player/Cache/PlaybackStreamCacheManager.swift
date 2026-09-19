import CryptoKit
import Foundation
import OSLog

/// Manages active HTTP stream disk cache servers for playback sessions.
actor PlaybackStreamCacheManager {
    static let shared = PlaybackStreamCacheManager()

    private var activeServer: PlaybackStreamCacheServer?
    private var activeSessionURL: URL?

    private init() {}

    /// Checks if a remote stream supports HTTP Range requests and resolves its total file length.
    func probeRangeSupport(
        url: URL,
        headers: [String: String] = [:]
    ) async -> (supportsRange: Bool, contentLength: Int64) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return (false, 0)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse {
                let acceptRanges = http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
                let length = http.expectedContentLength
                if length > 0 && acceptRanges {
                    return (true, length)
                }
            }
        } catch {
            diskCacheLog.warning("HEAD probe failed for \(url.absoluteString): \(error.localizedDescription), trying Range probe")
        }

        // Fallback: Test with Range: bytes=0-1
        var rangeReq = URLRequest(url: url)
        rangeReq.httpMethod = "GET"
        rangeReq.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        for (k, v) in headers { rangeReq.setValue(v, forHTTPHeaderField: k) }

        do {
            let (_, response) = try await URLSession.shared.data(for: rangeReq)
            if let http = response as? HTTPURLResponse, http.statusCode == 206 {
                if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                   let totalStr = contentRange.split(separator: "/").last,
                   let totalLength = Int64(totalStr) {
                    return (true, totalLength)
                }
            }
        } catch {
            diskCacheLog.warning("Range probe failed for \(url.absoluteString): \(error.localizedDescription)")
        }

        return (false, 0)
    }

    /// Prepares a hybrid disk cache server for a remote stream URL if Range requests are supported and caching is enabled.
    func prepareCacheServer(
        for remoteURL: URL,
        headers: [String: String] = [:],
        customLimitGB: Int? = nil
    ) async -> URL? {
        await stopActiveSession()

        let (supportsRange, contentLength) = await probeRangeSupport(url: remoteURL, headers: headers)
        guard supportsRange, contentLength > 10 * 1024 * 1024 else { // Require valid file length (>10MB)
            diskCacheLog.info("Stream does not support range requests or length is unknown. Bypassing disk cache proxy.")
            return nil
        }

        let storedLimit = ProfileSettings.current.integer(forKey: SettingsKey.hybridDiskCacheLimitGB)
        let limitGB = customLimitGB ?? (storedLimit > 0 ? storedLimit : 20)
        let limitBytes = Int64(limitGB) * 1024 * 1024 * 1024

        // Derive deterministic session ID so returning to the same stream reuses existing disk chunks
        let urlData = Data(remoteURL.absoluteString.utf8)
        let hash = SHA256.hash(data: urlData)
        let stableSessionID = hash.prefix(16).map { String(format: "%02x", $0) }.joined()

        let server = PlaybackStreamCacheServer(
            remoteURL: remoteURL,
            fileLength: contentLength,
            customHeaders: headers,
            sessionID: stableSessionID,
            maxDiskCacheSizeBytes: limitBytes
        )

        do {
            let localURL = try await server.start()
            activeServer = server
            activeSessionURL = remoteURL
            diskCacheLog.notice("Hybrid Disk Cache engaged for \(remoteURL.lastPathComponent) [session=\(stableSessionID)] -> \(localURL.absoluteString)")
            return localURL
        } catch {
            diskCacheLog.error("Failed to start PlaybackStreamCacheServer: \(error.localizedDescription)")
            return nil
        }
    }

    func stopActiveSession() async {
        if let server = activeServer {
            await server.stop()
            activeServer = nil
            activeSessionURL = nil
        }
    }

    func currentCachedFraction() async -> Double {
        if let server = activeServer {
            return await server.cachedFraction()
        }
        return 0
    }

    func currentCachedRanges() async -> [Range<Int64>] {
        if let server = activeServer {
            return await server.cachedByteRanges()
        }
        return []
    }
}
