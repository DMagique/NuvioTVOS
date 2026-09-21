## tvOS Beta 3.3.6

> **Install:** [NuvioTV-3.3.6-unsigned-release.ipa](https://github.com/bobsupra/NuvioTVOS/releases/download/tvos-beta-3.3.6/NuvioTV-3.3.6-unsigned-release.ipa) requires a compatible tvOS development or sideloading signing workflow before installation.

> **New beta alerts:** [Manage notifications](https://github.com/bobsupra/NuvioTVOS/subscription) → choose **Custom → Releases** · [Report a bug or suggest an idea](https://github.com/bobsupra/NuvioTVOS/issues/new/choose)

> 🎉 **Thank you for 100+ GitHub Stars!** A huge thank you to everyone in the community for supporting NuvioTVOS and helping reach 100+ stars on GitHub! Your feedback, issue reports, and testing make this possible.

### Binge-Watching Stream Auto-Selection

- **Release Group Continuity:** Added `BingeGroupStore.swift` to remember the stream release group (e.g. *Framestor*, *NTb*, *FLUX*) chosen for an episode.
- **Auto-Play Next Episode:** When auto-advancing to the next episode, Nuvio automatically selects the matching release group stream to ensure consistent quality, HDR format, and audio tracks.

### Live Scrubber Thumbnail Previews

- **Hardware-Accelerated Frame Extraction:** Overhauled timeline scrubbing in `AetherEngine+ScrubThumbnail.swift` and `FrameExtractor.swift`.
- **Hover Preview Bubble:** A live video thumbnail preview renders smoothly above the timeline scrubber as you swipe across the Apple TV remote clickpad (`ScrubberViews.swift`), verified by `PreciseSeekThumbnailTests.swift`.

### Player Controls & Remote Gestures Overhaul

- **Native Clickpad Gestures:** Pressing the remote clickpad center toggles play/pause, with seamless Up Arrow navigation into transport and sub-menus.
- **Enhanced Track Management:** Streamlined side panels for audio tracks, subtitle selector with timing offsets, and real-time audio latency calibration directly in player controls (`PlayerControls.swift`, `SidePanels.swift`).

### Catalog Rows & Collection Folder Performance

- **Fluid 60fps Catalog Scrolling:** Heavily optimized `TVCatalogRow.swift` with stable item identities to eliminate frame drops during fast navigation.
- **Focus Protection:** Deferred focus restoration in `CollectionFolderBrowseView.swift` guarantees the Apple TV remote focus never jumps or freezes when entering or dismissing collection folders.

### Native Search & Dictation Polish

- **Siri Voice Dictation:** Refined native search keyboard hosting (`NativeSearchView.swift`, `NetflixSearchView.swift`) with responsive dictation input and fluid focus handoff into poster result cards.

### Tests & Stability

- 383 automated unit and regression tests passing with 0 failures across playback gesture handling, scrub thumbnails, debrid caching, and catalog decoding.

### Known issues

- Picture in Picture requires a supported Apple TV 4K / tvOS 15+ device.
- Physical Apple TV playback, HDMI/HDR/Dolby Vision, AirPlay receivers, Atmos hardware, and live-TV paths still need real-device validation; the Apple TV Simulator cannot play AV1.
