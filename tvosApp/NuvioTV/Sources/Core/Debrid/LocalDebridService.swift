import Foundation

struct LocalDebridCachedItem: Sendable {
    let name: String?
    let size: Int64?
}

private actor RealDebridAvailabilityCache {
    static let shared = RealDebridAvailabilityCache()
    private var cache: [String: (item: LocalDebridCachedItem?, expiresAt: Date)] = [:]
    private var lastRequestTime = Date.distantPast
    private let minimumRequestInterval: TimeInterval = 1.0 // Real-Debrid rate limit: 1 req/sec

    func lookup(hashes: [String]) -> (cached: [String: LocalDebridCachedItem], missing: [String]) {
        let now = Date()
        var found: [String: LocalDebridCachedItem] = [:]
        var missing: [String] = []
        for hash in hashes {
            let lower = hash.lowercased()
            if let entry = cache[lower], entry.expiresAt > now {
                if let item = entry.item {
                    found[lower] = item
                }
            } else {
                missing.append(lower)
            }
        }
        return (found, missing)
    }

    func store(items: [String: LocalDebridCachedItem], checkedHashes: [String], ttl: TimeInterval = 300) {
        let expires = Date().addingTimeInterval(ttl)
        for hash in checkedHashes {
            let lower = hash.lowercased()
            cache[lower] = (items[lower], expires)
        }
    }

    func waitPacer() async {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRequestTime)
        if elapsed < minimumRequestInterval {
            let delay = minimumRequestInterval - elapsed
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        lastRequestTime = Date()
    }
}

struct LocalDebridService: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Queries the given debrid provider to determine which of the provided
    /// torrent hashes are already cached on their servers.
    func checkCached(
        provider: DebridProviderKind,
        apiKey: String,
        hashes: [String]
    ) async -> [String: LocalDebridCachedItem]? {
        let normalized = hashes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return [:] }

        switch provider {
        case .torbox:
            return await checkTorboxCached(apiKey: apiKey, hashes: normalized)
        case .realDebrid:
            return await checkRealDebridCached(apiKey: apiKey, hashes: normalized)
        case .premiumize:
            return await checkPremiumizeCached(apiKey: apiKey, hashes: normalized)
        default:
            return nil
        }
    }

    // MARK: - TorBox

    private func checkTorboxCached(apiKey: String, hashes: [String]) async -> [String: LocalDebridCachedItem]? {
        guard let url = URL(string: "https://api.torbox.app/v1/api/torrents/checkcached?format=object") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = ["hashes": hashes]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        request.httpBody = httpBody

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let success = json["success"] as? Bool, success,
                  let dataDict = json["data"] as? [String: Any] else {
                return nil
            }

            var result: [String: LocalDebridCachedItem] = [:]
            for (hash, itemVal) in dataDict {
                if let itemDict = itemVal as? [String: Any] {
                    let name = itemDict["name"] as? String
                    let size = (itemDict["size"] as? NSNumber)?.int64Value
                    result[hash.lowercased()] = LocalDebridCachedItem(name: name, size: size)
                }
            }
            return result
        } catch {
            return nil
        }
    }

    // MARK: - Real-Debrid

    private func checkRealDebridCached(apiKey: String, hashes: [String]) async -> [String: LocalDebridCachedItem]? {
        let (cached, missing) = await RealDebridAvailabilityCache.shared.lookup(hashes: hashes)
        if missing.isEmpty {
            return cached
        }

        await RealDebridAvailabilityCache.shared.waitPacer()

        let hashPath = missing.prefix(50).joined(separator: "/")
        guard let url = URL(string: "https://api.real-debrid.com/rest/1.0/torrents/instantAvailability/\(hashPath)") else { return cached }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return cached.isEmpty ? nil : cached }
            if http.statusCode == 429 {
                print("[LocalDebridService] Real-Debrid instantAvailability returned 429 (rate limited)")
                return cached.isEmpty ? nil : cached
            }
            guard 200..<300 ~= http.statusCode else { return cached.isEmpty ? nil : cached }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return cached.isEmpty ? nil : cached }

            var fetched: [String: LocalDebridCachedItem] = [:]
            for (hash, val) in json {
                guard let providerDict = val as? [String: Any],
                      let rdArray = providerDict["rd"] as? [[String: Any]],
                      !rdArray.isEmpty else {
                    continue
                }
                var firstName: String?
                var totalSize: Int64?
                if let firstVariant = rdArray.first {
                    for (_, fileInfoVal) in firstVariant {
                        if let fileInfo = fileInfoVal as? [String: Any] {
                            firstName = fileInfo["filename"] as? String
                            totalSize = (fileInfo["filesize"] as? NSNumber)?.int64Value
                            break
                        }
                    }
                }
                fetched[hash.lowercased()] = LocalDebridCachedItem(name: firstName, size: totalSize)
            }
            let checkedBatch = Array(missing.prefix(50))
            await RealDebridAvailabilityCache.shared.store(items: fetched, checkedHashes: checkedBatch)

            var merged = cached
            for (k, v) in fetched {
                merged[k] = v
            }
            return merged
        } catch {
            return cached.isEmpty ? nil : cached
        }
    }

    // MARK: - Premiumize

    private func checkPremiumizeCached(apiKey: String, hashes: [String]) async -> [String: LocalDebridCachedItem]? {
        var components = URLComponents(string: "https://www.premiumize.me/api/cache/check")
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "apikey", value: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        ]
        for hash in hashes {
            queryItems.append(URLQueryItem(name: "items[]", value: "magnet:?xt=urn:btih:\(hash)"))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { return nil }
        let request = URLRequest(url: url)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String, status == "success",
                  let responses = json["response"] as? [Bool] else {
                return nil
            }
            let filenames = json["filename"] as? [String?]
            let filesizes = json["filesize"] as? [NSNumber?]

            var result: [String: LocalDebridCachedItem] = [:]
            for (index, isCached) in responses.enumerated() where isCached {
                guard index < hashes.count else { continue }
                let hash = hashes[index].lowercased()
                let name = (filenames?.indices.contains(index) == true) ? filenames?[index] : nil
                let size = (filesizes?.indices.contains(index) == true) ? filesizes?[index]?.int64Value : nil
                result[hash] = LocalDebridCachedItem(name: name, size: size)
            }
            return result
        } catch {
            return nil
        }
    }
}
