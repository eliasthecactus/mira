# Changelog

All notable changes to Mira. Versions follow [Semantic Versioning](https://semver.org).

## [0.2.0-beta.2]

Still untested with a real Microsoft 4K Wireless Display Adapter.

### Added
- **Security:** MS-MICE stream encryption and PIN pairing (DTLS 1.2 over the MICE channel, PIN dialog / `--pin`). *Auto* tries a plain connection first and falls back to PIN pairing if the display ignores it. How data is protected with the DTLS key is unspecified in MS-MICE; Mira uses DTLS application-data records (verified against an OpenSSL-based mock, not yet against real hardware).
- **Automatic quality:** bitrate adapts to the Wi-Fi from RTCP loss reports, local send backlog and repeated keyframe requests (`--bitrate auto`, `--max-bitrate`).
- **Extend mode:** use the TV as a second screen via a virtual display (`--extend`); falls back to mirroring where macOS doesn't allow virtual displays.
- **Sound only on TV:** mutes the Mac's speakers while mirroring and restores them afterwards, even after a crash.
- The Mac no longer sleeps while mirroring.
- Reconnect to the last display on launch; global shortcut ⌃⌥⌘M to start/stop.
- `Mira doctor` reports whether Extend mode works on this Mac.
- Mock sink: `--security encrypted|pin`, `--pin`, `--loss` (with RTCP receiver reports).

### Fixed
- The CLI could exit before an encrypted STOP_PROJECTION was sent.
- Wrong-PIN and DTLS errors are reported as such instead of "could not reach".
- `Mira doctor` no longer reports port 7236 as busy because of a just-closed session.
- Setup instructions no longer claim the adapter can be configured from an Xbox (unverified).

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
