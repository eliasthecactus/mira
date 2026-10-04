# Changelog

All notable changes to Mira. Versions follow [Semantic Versioning](https://semver.org).

## [0.2.0-beta.1]

First public build. The full Miracast-over-Infrastructure pipeline works end-to-end against the bundled mock sink and decodes cleanly in ffmpeg, but **it has not been tested with a real Microsoft 4K Wireless Display Adapter yet.** Reports are very welcome (see the "Hardware report" issue template).

### Added
- MS-MICE signalling (SOURCE_READY / STOP_PROJECTION over TCP 7250)
- Wi-Fi Display RTSP source (M1–M8, keep-alives, IDR requests, pause/resume)
- Capability negotiation: 1080p30 → 720p30 → 640×480 by sink support and H.264 level
- Screen capture with ScreenCaptureKit, including system audio; choice of display
- H.264 Constrained Baseline (VideoToolbox), AAC-LC or LPCM audio
- MPEG-2 TS muxer and RTP (payload type 33) transport
- Menu bar app: discovery, connect by IP, resolution/bitrate/audio/display settings, test pattern, open at login, update check
- CLI: `list`, `connect`, `displays`, `doctor`, `--test-pattern`, `--dump-ts`, full protocol logging
- Auto-reconnect when a working session drops
- Discovery that keeps working with a VPN connected
- Mock sink (`tools/mock_sink.py`) and end-to-end test (`tools/e2e.sh`)
- Universal (Apple silicon + Intel) app, DMG, zip and Homebrew cask, built by GitHub Actions
