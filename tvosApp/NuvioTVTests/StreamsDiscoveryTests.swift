//
//  StreamsDiscoveryTests.swift
//  NuvioTVTests
//
//  Regression coverage for stream discovery behavior aligned with Android
//  StreamsRepository (stable instance ids, metadata preservation, request keys).
//

import XCTest
@testable import NuvioTV

private enum TestStreamError: Error { case failed }

final class StreamsDiscoveryTests: XCTestCase {

    func testStreamRequestRetryPolicyRetriesTransientErrorsOnly() {
        XCTAssertTrue(StreamsRepository.StreamRequestRetryPolicy.shouldRetry(URLError(.timedOut)))
        XCTAssertTrue(StreamsRepository.StreamRequestRetryPolicy.shouldRetry(URLError(.networkConnectionLost)))
        XCTAssertTrue(StreamsRepository.StreamRequestRetryPolicy.shouldRetry(URLError(.cannotConnectToHost)))
        XCTAssertFalse(StreamsRepository.StreamRequestRetryPolicy.shouldRetry(URLError(.cancelled)))
        XCTAssertFalse(StreamsRepository.StreamRequestRetryPolicy.shouldRetry(URLError(.badServerResponse)))
        XCTAssertFalse(StreamsRepository.StreamRequestRetryPolicy.shouldRetry(TestStreamError.failed))
    }

    func testMergingExternalSubtitlesPreservesTorrentMetadata() {
        let torrent = NuvioStream(
            url: nil,
            name: "1080p WEB-DL",
            description: "Torrentio\n12 GB",
            addonName: "Torrentio",
            subtitles: [
                NuvioSubtitle(url: "https://example.com/a.srt", language: "en", label: "English")
            ],
            addonLogoURL: "https://example.com/logo.png",
            infoHash: "abcdef0123456789abcdef0123456789abcdef01",
            fileIdx: 2,
            sources: ["tracker:udp://tracker.example/announce"],
            filename: "Show.S01E01.1080p.mkv",
            httpHeaders: [
                "Referer": "https://portal.example/",
                "User-Agent": "ExamplePlayer/1.0"
            ]
        )

        let external = [
            NuvioSubtitle(url: "https://example.com/b.srt", language: "es", label: "Spanish", source: "OpenSubtitles")
        ]
        let merged = torrent.mergingExternalSubtitles(external)

        XCTAssertNil(merged.url)
        XCTAssertEqual(merged.infoHash, torrent.infoHash)
        XCTAssertEqual(merged.fileIdx, 2)
        XCTAssertEqual(merged.sources, torrent.sources)
        XCTAssertEqual(merged.filename, torrent.filename)
        XCTAssertEqual(merged.addonLogoURL, torrent.addonLogoURL)
        XCTAssertEqual(merged.addonName, "Torrentio")
        XCTAssertEqual(merged.httpHeaders, torrent.httpHeaders)
        XCTAssertEqual(merged.subtitles.count, 2)
        XCTAssertTrue(merged.subtitles.contains { $0.url == "https://example.com/b.srt" })
    }

    func testMergingExternalSubtitlesDedupesByURL() {
        let stream = NuvioStream(
            url: "https://cdn.example/video.mp4",
            name: "Stream",
            description: nil,
            addonName: "AIO",
            subtitles: [
                NuvioSubtitle(url: "https://example.com/same.srt", language: "en", label: "EN")
            ]
        )
        let external = [
            NuvioSubtitle(url: "https://example.com/same.srt", language: "en", label: "EN2"),
            NuvioSubtitle(url: "https://example.com/new.srt", language: "fr", label: "FR")
        ]
        let merged = stream.mergingExternalSubtitles(external)
        XCTAssertEqual(merged.subtitles.count, 2)
        XCTAssertEqual(merged.url, stream.url)
    }

    func testRequestKeyIncludesTypeIdSeasonEpisode() {
        let key = StreamsRepository.requestKey(type: "series", videoId: "tt1:1:2", season: 1, episode: 2)
        XCTAssertEqual(key, "series::tt1:1:2::1::2")

        let movieKey = StreamsRepository.requestKey(type: "movie", videoId: "tt99")
        XCTAssertEqual(movieKey, "movie::tt99::::")
    }

    func testSeasonEpisodeParsedFromVideoId() {
        let se = StreamsRepository.seasonEpisode(fromVideoId: "tt0944947:2:5")
        XCTAssertEqual(se.season, 2)
        XCTAssertEqual(se.episode, 5)

        let movie = StreamsRepository.seasonEpisode(fromVideoId: "tt0111161")
        XCTAssertNil(movie.season)
        XCTAssertNil(movie.episode)
    }

    func testStableAddonIdIncludesManifestURLLikeAndroid() {
        let urlA = URL(string: "https://torrentio.strem.fun/manifest.json")!
        let urlB = URL(string: "https://torrentio.strem.fun/qualityfilter=480p/manifest.json")!
        let idA = StreamsRepository.stableAddonId(manifestId: "com.stremio.torrentio.addon", manifestURL: urlA)
        let idB = StreamsRepository.stableAddonId(manifestId: "com.stremio.torrentio.addon", manifestURL: urlB)

        XCTAssertEqual(idA, "addon:com.stremio.torrentio.addon:https://torrentio.strem.fun/manifest.json")
        XCTAssertEqual(idB, "addon:com.stremio.torrentio.addon:https://torrentio.strem.fun/qualityfilter=480p/manifest.json")
        XCTAssertNotEqual(idA, idB, "Same manifest.id with different URLs must not collide")
    }

    func testAddonStreamGroupUsesStableIdNotDisplayName() {
        let group = AddonStreamGroup(
            addonId: "addon:com.stremio.torrentio.addon:https://example.com/manifest.json",
            displayName: "Torrentio",
            streams: [],
            isLoading: true
        )
        XCTAssertEqual(group.id, group.addonId)
        XCTAssertNotEqual(group.id, group.displayName)
    }

    func testManifestCacheStoresSuccessOnly() async {
        let cache = StreamManifestCache()
        let url = URL(string: "https://example.com/manifest.json")!
        let missing = await cache.success(for: url)
        XCTAssertNil(missing)

        let manifest = StreamAddonManifest(
            id: "com.example.addon",
            name: "Example",
            logo: nil,
            types: ["movie"],
            idPrefixes: ["tt"],
            resources: nil
        )
        await cache.storeSuccess(manifest, for: url)
        let cached = await cache.success(for: url)
        XCTAssertEqual(cached?.id, "com.example.addon")
        XCTAssertEqual(cached?.name, "Example")
    }

    func testTMDBMetadataUsesImdbIDForCanonicalStreamIdentity() throws {
        let data = Data(
            #"{"id":"tmdb:687163","name":"Example","type":"movie","imdb_id":" tt12042730 "}"#.utf8
        )
        let decoded = try JSONDecoder().decode(CinemetaMeta.self, from: data)
        let meta = decoded.toMeta(fallbackType: "movie")

        XCTAssertEqual(meta.imdbId, "tt12042730")
        XCTAssertEqual(meta.streamId, "tt12042730")
    }

    func testFullMetadataRequiresCanonicalImdbIdentityForMovies() {
        let tmdbOnly = makeMeta(id: "tmdb:687163", imdbId: nil)
        let canonical = makeMeta(id: "tmdb:687163", imdbId: "tt12042730")
        let canonicalId = makeMeta(id: "tt12042730", imdbId: nil)

        XCTAssertFalse(CinemetaCatalogRepository.isFullMetadata(tmdbOnly))
        XCTAssertTrue(CinemetaCatalogRepository.isFullMetadata(canonical))
        XCTAssertTrue(CinemetaCatalogRepository.isFullMetadata(canonicalId))
    }

    func testSeriesWithEmptyVideosIsNotFullMetadata() {
        let meta = makeMeta(id: "tt12042730", imdbId: "tt12042730", type: "series", videos: [])

        XCTAssertFalse(CinemetaCatalogRepository.isFullMetadata(meta))
    }

    func testVideoInferredMovieWithCanonicalIdentityIsFullMetadata() {
        let meta = NuvioMeta(
            id: "tt12042730",
            name: "Example",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt12042730",
            tmdbId: nil,
            type: "movie",
            year: nil,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            status: nil,
            videos: [NuvioVideo(id: "tt12042730:1:1", title: "Episode", season: 1, episode: 1, thumbnail: nil, overview: nil, released: nil, rating: nil)],
            trailerYtIds: nil,
            externalRatings: nil
        )

        XCTAssertTrue(meta.isSeries)
        XCTAssertTrue(CinemetaCatalogRepository.isFullMetadata(meta))
    }

    func testUnicodeDigitIMDbIDIsRejected() {
        XCTAssertNil(NuvioMeta.canonicalImdbID(from: "tt१२३४५६७"))
    }

    func testCanonicalIMDbMetadataUsesSeriesFirstFallbackOrdering() {
        XCTAssertEqual(
            CinemetaCatalogRepository.cinemetaMetadataTypesToTry(
                primaryType: "series",
                canonicalImdbID: NuvioMeta.canonicalImdbID(from: " rpdb:TT12042730 ")
            ),
            ["series", "movie"]
        )
        XCTAssertEqual(
            CinemetaCatalogRepository.cinemetaMetadataTypesToTry(
                primaryType: "series",
                canonicalImdbID: "tmdb:123"
            ),
            ["series"]
        )
    }

    func testRPDBWrappedMetadataUsesCanonicalImdbIdentity() throws {
        let data = Data(
            #"{"id":" rpdb:TT1234567 ","name":"Example","type":"movie"}"#.utf8
        )
        let decoded = try JSONDecoder().decode(CinemetaMeta.self, from: data)
        let meta = decoded.toMeta(fallbackType: "movie")

        XCTAssertEqual(meta.imdbId, "tt1234567")
        XCTAssertEqual(meta.streamId, "tt1234567")
    }

    func testProxyRequestHeadersAreRetainedForPlayback() throws {
        let data = Data(
            #"""
            {
              "url": "https://media.example/stream.m3u8",
              "name": "KhmerAve",
              "behaviorHints": {
                "proxyHeaders": {
                  "request": {
                    "Referer": "https://ok.ru/",
                    "User-Agent": "Mozilla/5.0"
                  },
                  "response": { "Set-Cookie": "must-not-be-forwarded" }
                }
              }
            }
            """#.utf8
        )

        let raw = try JSONDecoder().decode(StreamAddonStreamDTO.self, from: data)
        let stream = try XCTUnwrap(raw.toNuvioStream(addonName: "KhmerDub"))

        XCTAssertEqual(
            stream.httpHeaders,
            ["Referer": "https://ok.ru/", "User-Agent": "Mozilla/5.0"]
        )
    }

    // MARK: - Stream picker list derivation / focus isolation

    func testDisplayedStreamsUpdateWhenFilterOrSortChanges() {
        let torrentio = makeStream(url: "https://cdn.example/a.mkv", name: "4K HDR", addon: "Torrentio")
        let aio = makeStream(url: "https://cdn.example/b.mkv", name: "1080p", addon: "AIOStreams")
        let groups = [
            AddonStreamGroup(addonId: "addon:torrentio", displayName: "Torrentio", streams: [torrentio], isLoading: false),
            AddonStreamGroup(addonId: "addon:aio", displayName: "AIOStreams", streams: [aio], isLoading: false)
        ]
        let flat = [torrentio, aio]

        let allDefault = StreamPickerListBuilder.displayedStreams(
            streams: flat, groups: groups, selectedAddonId: nil, sortOption: .default, includeDebrid: false
        )
        XCTAssertEqual(allDefault.map(\.id), [torrentio.id, aio.id])

        let onlyTorrentio = StreamPickerListBuilder.displayedStreams(
            streams: flat, groups: groups, selectedAddonId: "addon:torrentio", sortOption: .default, includeDebrid: false
        )
        XCTAssertEqual(onlyTorrentio.map(\.id), [torrentio.id])

        let byName = StreamPickerListBuilder.displayedStreams(
            streams: flat, groups: groups, selectedAddonId: nil, sortOption: .name, includeDebrid: false
        )
        XCTAssertEqual(byName.map(\.id), [aio.id, torrentio.id], "Name sort is alphabetical by stream name")

        let byQuality = StreamPickerListBuilder.displayedStreams(
            streams: flat, groups: groups, selectedAddonId: nil, sortOption: .quality, includeDebrid: false
        )
        XCTAssertEqual(byQuality.first?.id, torrentio.id, "4K should rank above 1080p")
    }

    func testFocusChangeDoesNotChangeDerivedStreamList() {
        let streams = [
            makeStream(url: "https://cdn.example/1.mkv", name: "1080p", addon: "A"),
            makeStream(url: "https://cdn.example/2.mkv", name: "720p", addon: "B")
        ]
        let groups = [
            AddonStreamGroup(addonId: "a", displayName: "A", streams: [streams[0]], isLoading: false),
            AddonStreamGroup(addonId: "b", displayName: "B", streams: [streams[1]], isLoading: false)
        ]

        let cacheKeyA = StreamPickerListBuilder.cacheKey(
            revision: 7, selectedAddonId: nil, sortOption: .default, includeDebrid: false
        )
        let listA = StreamPickerListBuilder.displayedStreams(
            streams: streams, groups: groups, selectedAddonId: nil, sortOption: .default, includeDebrid: false
        )
        // Simulate a focus-only re-render: the repository revision and list
        // options are unchanged, so the constant-size cache key stays equal.
        let cacheKeyB = StreamPickerListBuilder.cacheKey(
            revision: 7, selectedAddonId: nil, sortOption: .default, includeDebrid: false
        )
        let listB = StreamPickerListBuilder.displayedStreams(
            streams: streams, groups: groups, selectedAddonId: nil, sortOption: .default, includeDebrid: false
        )

        XCTAssertEqual(cacheKeyA, cacheKeyB)
        XCTAssertEqual(listA.map(\.id), listB.map(\.id))
        XCTAssertEqual(listA.map(\.id), streams.map(\.id))
    }

    func testRevisionInvalidatesCacheWhenSubtitlesChangeWithoutIdentityChange() {
        let original = makeStream(
            url: "https://cdn.example/same.mkv",
            name: "1080p",
            addon: "AIOStreams"
        )
        let decorated = original.mergingExternalSubtitles([
            NuvioSubtitle(
                url: "https://subs.example/external.srt",
                language: "en",
                label: "English",
                source: "OpenSubtitles"
            )
        ])

        XCTAssertEqual(original.id, decorated.id)

        let before = StreamPickerListBuilder.cacheKey(
            revision: 20, selectedAddonId: nil, sortOption: .default, includeDebrid: false
        )
        let after = StreamPickerListBuilder.cacheKey(
            revision: 21, selectedAddonId: nil, sortOption: .default, includeDebrid: false
        )
        XCTAssertNotEqual(before, after, "Every repository publication must invalidate the picker cache")

        let refreshed = StreamPickerListBuilder.displayedStreams(
            streams: [decorated],
            groups: [
                AddonStreamGroup(
                    addonId: "aio",
                    displayName: "AIOStreams",
                    streams: [decorated],
                    isLoading: false
                )
            ],
            selectedAddonId: nil,
            sortOption: .default,
            includeDebrid: false
        )
        XCTAssertEqual(refreshed.first?.subtitles.map(\.url), ["https://subs.example/external.srt"])
    }

    func testAV1DetectionIgnoresSubtitleData() {
        let av1InName = makeStream(
            url: "https://cdn.example/av1.mkv",
            name: "Title AV1 1080p",
            addon: "Torrentio",
            subtitles: []
        )
        let av1OnlyInSubtitle = makeStream(
            url: "https://cdn.example/h264.mkv",
            name: "Title 1080p x264",
            addon: "Torrentio",
            subtitles: [
                NuvioSubtitle(
                    url: "https://example.com/track-av1-metadata.srt",
                    language: "av1",
                    label: "AV1 Forced"
                )
            ]
        )
        let av01InFilename = NuvioStream(
            url: "https://cdn.example/file.mkv",
            name: "Title",
            description: nil,
            addonName: "Torrentio",
            filename: "Show.S01E01.AV01.mkv"
        )

        XCTAssertTrue(SmartPlaybackSelector.isAV1LabeledStream(av1InName))
        XCTAssertFalse(
            SmartPlaybackSelector.isAV1LabeledStream(av1OnlyInSubtitle),
            "Subtitle language/label/URL must not trigger AV1 filtering"
        )
        XCTAssertTrue(SmartPlaybackSelector.isAV1LabeledStream(av01InFilename))
    }

    func testStableStreamOrderingAndIdentities() {
        let a = makeStream(url: "https://cdn.example/a.mkv", name: "A", addon: "Torrentio")
        let b = makeStream(url: "https://cdn.example/b.mkv", name: "B", addon: "AIO")
        let debridOnly = NuvioStream(
            url: nil,
            name: "C debrid",
            description: "12 GB",
            addonName: "Torrentio",
            infoHash: "abcdef0123456789abcdef0123456789abcdef01",
            fileIdx: 0
        )
        let shell = NuvioStream(url: nil, name: "Shell", description: "x", addonName: "X")

        // URL / infoHash identities are stable across repeated access.
        XCTAssertEqual(a.id, a.id)
        XCTAssertEqual(a.id, "https://cdn.example/a.mkv")
        XCTAssertEqual(debridOnly.id, "abcdef0123456789abcdef0123456789abcdef01:0")
        XCTAssertEqual(shell.id, shell.id)
        XCTAssertFalse(shell.id.contains("-"), "Fallback id must not be a fresh UUID")

        let groups = [
            AddonStreamGroup(addonId: "t", displayName: "Torrentio", streams: [a, debridOnly], isLoading: false),
            AddonStreamGroup(addonId: "aio", displayName: "AIO", streams: [b], isLoading: false)
        ]
        // "All" preserves add-on group order (Android-style), not alphabetical addon names.
        let all = StreamPickerListBuilder.displayedStreams(
            streams: [a, debridOnly, b],
            groups: groups,
            selectedAddonId: nil,
            sortOption: .default,
            includeDebrid: true
        )
        XCTAssertEqual(all.map(\.id), [a.id, debridOnly.id, b.id])

        // Without debrid, torrent-only streams drop out; order of remaining stays.
        let noDebrid = StreamPickerListBuilder.displayedStreams(
            streams: [a, debridOnly, b],
            groups: groups,
            selectedAddonId: nil,
            sortOption: .default,
            includeDebrid: false
        )
        XCTAssertEqual(noDebrid.map(\.id), [a.id, b.id])
    }

    // MARK: - Helpers

    private func makeStream(
        url: String,
        name: String,
        addon: String,
        subtitles: [NuvioSubtitle] = []
    ) -> NuvioStream {
        NuvioStream(
            url: url,
            name: name,
            description: nil,
            addonName: addon,
            subtitles: subtitles
        )
    }

    private func makeMeta(
        id: String,
        imdbId: String?,
        type: String = "movie",
        videos: [NuvioVideo]? = nil
    ) -> NuvioMeta {
        return NuvioMeta(
            id: id,
            name: "Example",
            description: "Description",
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: imdbId,
            tmdbId: 687163,
            type: type,
            year: 2024,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: ["Director"],
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            status: nil,
            videos: videos,
            trailerYtIds: nil,
            externalRatings: nil
        )
    }

    // MARK: - Addon Transport URLs & Type Equivalence Tests

    func testAddonTransportUrlsPreservesQueryAndEncodesIds() {
        let manifestWithQuery = URL(string: "https://penguplay.com/stremio/manifest.json?token=secret123&profile=main")!
        let streamURL = AddonTransportUrls.buildResourceURL(
            manifestURL: manifestWithQuery,
            resource: "stream",
            type: "series",
            id: "tt1234567:1:5"
        )
        XCTAssertEqual(
            streamURL?.absoluteString,
            "https://penguplay.com/stremio/stream/series/tt1234567%3A1%3A5.json?token=secret123&profile=main"
        )

        let simpleManifest = URL(string: "https://v3-cinemeta.strem.io/manifest.json")!
        let metaURL = AddonTransportUrls.buildResourceURL(
            manifestURL: simpleManifest,
            resource: "meta",
            type: "movie",
            id: "tt9876543"
        )
        XCTAssertEqual(
            metaURL?.absoluteString,
            "https://v3-cinemeta.strem.io/meta/movie/tt9876543.json"
        )

        let pathConfiguredManifest = URL(string: "https://comet.example.com/eyJmb28iOiJiYXIifQ==/manifest.json")!
        let cometStreamURL = AddonTransportUrls.buildResourceURL(
            manifestURL: pathConfiguredManifest,
            resource: "stream",
            type: "series",
            id: "tt1234567:2:3"
        )
        XCTAssertEqual(
            cometStreamURL?.absoluteString,
            "https://comet.example.com/eyJmb28iOiJiYXIifQ==/stream/series/tt1234567%3A2%3A3.json"
        )
    }

    func testSupportsResourceNormalizesTvAndSeriesTypes() throws {
        let manifestJson = """
        {
            "id": "org.pengu.stream",
            "name": "PenguPlay",
            "resources": [
                {
                    "name": "stream",
                    "types": ["tv", "movie"],
                    "idPrefixes": ["tt"]
                }
            ]
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(StreamAddonManifest.self, from: manifestJson)

        // "series" should match "tv"
        XCTAssertTrue(manifest.supportsResource("stream", type: "series", id: "tt1234567:1:1"))
        // "tv" matches "tv"
        XCTAssertTrue(manifest.supportsResource("stream", type: "tv", id: "tt1234567:1:1"))
        // "movie" matches "movie"
        XCTAssertTrue(manifest.supportsResource("stream", type: "movie", id: "tt1234567"))
        // "movies" matches "movie"
        XCTAssertTrue(manifest.supportsResource("stream", type: "movies", id: "tt1234567"))
        // Non-matching id prefix should fail
        XCTAssertFalse(manifest.supportsResource("stream", type: "series", id: "kitsu:1234"))
    }

    // MARK: - Stream Picker Pagination & Lazy Slicing

    private func makePaginationTestStreams(count: Int, addon: String = "Torrentio") -> [NuvioStream] {
        (1...count).map { i in
            NuvioStream(
                url: "https://example.com/stream\(i).mp4",
                name: "Stream \(i) - 1080p",
                description: "\(addon)\n\(i) GB",
                addonName: addon
            )
        }
    }

    func testPaginatedSliceWithEmptyStreamsReturnsEmpty() {
        let empty: [NuvioStream] = []
        let slice = StreamPickerListBuilder.paginatedSlice(streams: empty, limit: 20)
        XCTAssertTrue(slice.isEmpty)
        XCTAssertFalse(StreamPickerListBuilder.hasMorePages(totalCount: 0, currentLimit: 20))
    }

    func testPaginatedSliceWithZeroOrNegativeLimitReturnsEmpty() {
        let streams = makePaginationTestStreams(count: 10)
        XCTAssertTrue(StreamPickerListBuilder.paginatedSlice(streams: streams, limit: 0).isEmpty)
        XCTAssertTrue(StreamPickerListBuilder.paginatedSlice(streams: streams, limit: -5).isEmpty)
    }

    func testPaginatedSliceWithinFirstPage() {
        let streams = makePaginationTestStreams(count: 50)
        let page1 = StreamPickerListBuilder.paginatedSlice(streams: streams, limit: 20)
        XCTAssertEqual(page1.count, 20)
        XCTAssertEqual(page1.first?.name, "Stream 1 - 1080p")
        XCTAssertEqual(page1.last?.name, "Stream 20 - 1080p")
        XCTAssertTrue(StreamPickerListBuilder.hasMorePages(totalCount: streams.count, currentLimit: 20))
    }

    func testPaginatedSliceExpandingLimitLoadsNextPages() {
        let streams = makePaginationTestStreams(count: 50)

        let page1 = StreamPickerListBuilder.paginatedSlice(streams: streams, limit: 20)
        XCTAssertEqual(page1.count, 20)

        let page2 = StreamPickerListBuilder.paginatedSlice(streams: streams, limit: 40)
        XCTAssertEqual(page2.count, 40)
        XCTAssertEqual(page2.first?.name, "Stream 1 - 1080p")
        XCTAssertEqual(page2[19].name, "Stream 20 - 1080p")
        XCTAssertEqual(page2[20].name, "Stream 21 - 1080p")
        XCTAssertEqual(page2.last?.name, "Stream 40 - 1080p")
        XCTAssertTrue(StreamPickerListBuilder.hasMorePages(totalCount: streams.count, currentLimit: 40))

        let page3 = StreamPickerListBuilder.paginatedSlice(streams: streams, limit: 60)
        XCTAssertEqual(page3.count, 50)
        XCTAssertEqual(page3.last?.name, "Stream 50 - 1080p")
        XCTAssertFalse(StreamPickerListBuilder.hasMorePages(totalCount: streams.count, currentLimit: 60))
    }

    func testPaginatedSliceWithLimitExceedingTotalCount() {
        let streams = makePaginationTestStreams(count: 7)
        let slice = StreamPickerListBuilder.paginatedSlice(streams: streams, limit: 20)
        XCTAssertEqual(slice.count, 7)
        XCTAssertFalse(StreamPickerListBuilder.hasMorePages(totalCount: streams.count, currentLimit: 20))
    }

    func testPaginationWithDisplayedStreamsAndAddonFilter() {
        let addon1Streams = makePaginationTestStreams(count: 30, addon: "Torrentio")
        let addon2Streams = makePaginationTestStreams(count: 15, addon: "MediaFusion")
        let allStreams = addon1Streams + addon2Streams

        let group1 = AddonStreamGroup(
            addonId: "torrentio",
            displayName: "Torrentio",
            streams: addon1Streams,
            isLoading: false
        )
        let group2 = AddonStreamGroup(
            addonId: "mediafusion",
            displayName: "MediaFusion",
            streams: addon2Streams,
            isLoading: false
        )

        // All streams: 45 items total, 20 on first page
        let allDisplayed = StreamPickerListBuilder.displayedStreams(
            streams: allStreams,
            groups: [group1, group2],
            selectedAddonId: nil,
            sortOption: .default,
            includeDebrid: true
        )
        XCTAssertEqual(allDisplayed.count, 45)
        let allPage1 = StreamPickerListBuilder.paginatedSlice(streams: allDisplayed, limit: 20)
        XCTAssertEqual(allPage1.count, 20)
        XCTAssertTrue(StreamPickerListBuilder.hasMorePages(totalCount: allDisplayed.count, currentLimit: 20))

        // Filter by MediaFusion: 15 items total, 15 on first page (hasMore is false)
        let filteredDisplayed = StreamPickerListBuilder.displayedStreams(
            streams: allStreams,
            groups: [group1, group2],
            selectedAddonId: "mediafusion",
            sortOption: .default,
            includeDebrid: true
        )
        XCTAssertEqual(filteredDisplayed.count, 15)
        let filteredPage1 = StreamPickerListBuilder.paginatedSlice(streams: filteredDisplayed, limit: 20)
        XCTAssertEqual(filteredPage1.count, 15)
        XCTAssertFalse(StreamPickerListBuilder.hasMorePages(totalCount: filteredDisplayed.count, currentLimit: 20))
    }

    func testSmartPlaybackSelectorEvaluatesFullStreamPool() {
        // Construct 50 streams where only stream 48 has a 4K resolution
        let streams = (1...50).map { i in
            NuvioStream(
                url: "https://example.com/stream\(i).mp4",
                name: i == 48 ? "Movie 4K UHD Remux" : "Movie 720p WEB-DL",
                description: "Size \(i) GB",
                addonName: "Torrentio"
            )
        }

        // Auto-play selector must be able to select the 4K stream regardless of UI page limit
        let best = SmartPlaybackSelector.bestStream(
            from: streams,
            qualityPreference: "Highest",
            subtitleLanguages: [],
            shouldMatchSubtitles: false,
            includeDebrid: true,
            cachedOnly: false
        )
        XCTAssertNotNil(best)
        XCTAssertEqual(best?.name, "Movie 4K UHD Remux")
    }
}

