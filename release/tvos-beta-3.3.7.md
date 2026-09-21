## tvOS Beta 3.3.7

> **Install:** [NuvioTV-3.3.7-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.3.7/NuvioTV-3.3.7-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

> 🎉 **Thank you for 100+ GitHub Stars!** A huge thank you to everyone in the community for supporting NuvioTVOS and helping reach 100+ stars on GitHub! Your feedback, issue reports, and testing make this possible.

### High-Throughput Stream Caching Architecture

- **Local Stream Cache & Proxy Server:** Integrated a resilient local HTTP caching proxy (`PlaybackStreamCacheServer.swift`, `PlaybackStreamCacheManager.swift`, `PlaybackStreamDiskCache.swift`) to pre-buffer media segments onto disk and memory.
- **Configurable Cache Limits & Policies:** Fine-tune maximum stream cache sizes, prefetch margins, and eviction strategies directly in playback settings (`PlaybackCacheSettings.swift`), backed by comprehensive unit tests (`PlaybackStreamCacheTests.swift`).

### Direct Jellyfin & SMB Media Library Indexing

- **Direct SMB Share Indexing:** Faster scanning, metadata extraction, and robust reconnect handling for local SMB file shares (`SMBLibraryIndex.swift`).
- **Jellyfin Library Integration:** Enriched metadata resolution, directory structure traversal, and synchronized watch status with remote Jellyfin instances (`JellyfinLibraryIndex.swift`).

### Intro & Outro Auto-Skip Detection

- **IntroDB Integration:** Automated skip triggers with high-precision timestamp markers (`IntroDBSkipService.swift`) to smoothly skip show intros and recap segments.

### Playback Engine & Buffering Stability

- **Adaptive Playback Transitions:** Hardened stream loading state machines and playback controller lifecycles (`AetherPlaybackController.swift`, `PlayerView+Lifecycle.swift`, `PlayerView+Layers.swift`).
- **Buffering Policy Refinements:** Streamlined buffering HUD and network fluctuation recovery to ensure unbroken playback.

### AltStore, SideStore & Feather Repository Feed

- **Multi-Source Sideloading Feed:** Updated `apps.json` with complete release history, bundle metadata, and fast direct downloads for AltStore, SideStore, and Feather app managers.

### Tests & Stability

- 365 automated unit and regression tests passing with 0 failures across stream caching, profile isolation, playback policies, scrobble tracking, and catalog decoding.

### Known issues

- Picture in Picture requires a supported Apple TV 4K / tvOS 15+ device.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
