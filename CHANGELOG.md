# Changelog

All notable changes to Mira. Versions follow [Semantic Versioning](https://semver.org).

## [0.2.0-beta.6]

### Added
- **Google Cast:** mirror to Chromecast, Google TV / Android TV and TVs with Chromecast built-in. Mira speaks Cast Streaming, the protocol Chrome uses for "Cast screen": TLS control channel, the TV's built-in mirroring receiver, encrypted real-time RTP (AES-128 per frame) with acknowledgements and retransmission of lost packets, key frames on request. H.264, or HEVC for 4K where supported; Opus audio. About 250 ms of delay.
- **DLNA (experimental):** smart TVs without Cast or Miracast over Wi-Fi (older Samsung, LG, Philips, ...) play Mira's live MPEG-TS stream in their media player, with 2-5 s of delay. `--dlna-url` for networks that block discovery.
- Discovery finds Miracast, Google Cast and DLNA displays; connecting by IP detects the protocol (`--cast`, `--miracast`, `--dlna` to choose).
- `tools/mock_cast.py` / `tools/e2e_cast.sh` and `tools/mock_dlna.py` / `tools/e2e_dlna.sh`; CI runs both.

### Changed
- The media pipeline is shared by all protocols; each protocol is a transport. The AAC encoder can also produce Opus.
- Stopping mirroring on the TV ends the session normally instead of reporting an error.

## [0.2.0-beta.5]

### Added
- **Miracast 2 / HEVC:** Mira now reads the display's `wfd2_video_formats` (Miracast R2) and Microsoft's `wfdx_video_formats` and can stream **HEVC (H.265) Main**, used automatically for 4K when the display supports it (`--codec auto|h264|hevc`, *Codec* in the menu). MPEG-TS stream type 0x24, VPS/SPS/PPS on every keyframe, bitrate kept within the negotiated HEVC level. Macs without an HEVC encoder stay on H.264.
- **Input from the TV (UIBC):** a keyboard, mouse or touch screen at the receiver can control the Mac. Generic and HID input (with a HID report descriptor parser), mapped back through the letterbox, posted as macOS events. Off by default; needs the Accessibility permission. `--remote-input`, *Allow TV input* in the menu.
- `--legacy-formats` negotiates like a Miracast 1 source, for displays that misbehave.
- `mira doctor` reports HEVC encoder support and the Accessibility permission.
- Mock sink: `--wfd2`, `--wfdx`, `--expect-codec`, `--strict-m3` and `--uibc`; CI runs 4K over R2, HEVC, a strict sink and UIBC end to end.

### Fixed
- 4K was advertised through bits 17-21 of the Miracast 1 resolution table, which are reserved there. Real displays offer 4K only through `wfd2_video_formats` / `wfdx_video_formats` (each with its own numbering), which Mira now uses. An R2 display gets a pure R2 request (`wfd2_*` parameters only), as the spec requires.
- Constrained High used CABAC, which Wi-Fi Display forbids for that profile; it now uses CAVLC (CABAC only with the R2 "Restricted High 2" profile).
- If a display rejects the extended capability request or the chosen format, Mira retries with the Miracast 1 basics instead of failing.
- HEVC fell behind real time at 4K because VideoToolbox's HEVC encoder struggles with large absolute timestamps; the encoder now gets session-relative ones.

### Not possible
- HDCP needs keys that are only issued to licensed hardware makers, and DRM-protected video can't be screen-captured on macOS anyway. See the README.

## [0.2.0-beta.4]

### Fixed
- The Share menu only offered "Entire screen" until Screen Recording permission was granted. Apps are now listed without it, and the window section offers to request the permission.

### Changed
- ASCII only: no emoji or special characters in log output, CLI output, docs or source. Doctor uses [ok] / [warn] / [info]; shortcuts are written Ctrl+Opt+Cmd+M / Ctrl+Opt+Cmd+P. Names from the system or network are transliterated in logs (the name sent to the TV is unchanged).

## [0.2.0-beta.3]

### Added
- **Share one app or one window** instead of the whole screen (everything else stays black), switchable live during a session. `--app`, `--window`, `mira windows`.
- **Privacy pause** (Ctrl+Opt+Cmd+P, menu button, `p` in the CLI, `SIGUSR1`): freezes or blanks the TV and silences audio, e.g. while typing a password.
- **Low-latency mode:** about 100 ms instead of 200 ms (LPCM audio, smaller buffer, VideoToolbox low-latency rate control). `--low-latency`.
- **4K:** 3840x2160 with H.264 (Constrained High, level 5.1/5.2) when the display advertises it. `--resolution 4k`; auto quality goes up to 30 Mbit/s for 4K. `--probe-wfd2` logs the display's Miracast 2 capabilities.
- **60 fps** option in the menu.
- **In-app updates:** downloads the newest GitHub release, verifies checksum and signature, replaces the app and restarts. `mira update`.
- **Diagnostics export:** one zip with log, doctor output, system/network info and crash reports. `mira diagnose`.
- **Windows PC as receiver:** setup guide in the README, and a longer wait for Windows' "allow projection" prompt.
- The log rotates at 10 MB.

### Changed
- The Constrained Baseline/High flags are set in the SPS to match what Mira signals in the negotiation.

## [0.2.0-beta.2]

Still untested with a real Microsoft 4K Wireless Display Adapter.

### Added
- **Security:** MS-MICE stream encryption and PIN pairing (DTLS 1.2 over the MICE channel, PIN dialog / `--pin`). *Auto* tries a plain connection first and falls back to PIN pairing if the display ignores it. How data is protected with the DTLS key is unspecified in MS-MICE; Mira uses DTLS application-data records (verified against an OpenSSL-based mock, not yet against real hardware).
- **Automatic quality:** bitrate adapts to the Wi-Fi from RTCP loss reports, local send backlog and repeated keyframe requests (`--bitrate auto`, `--max-bitrate`).
- **Extend mode:** use the TV as a second screen via a virtual display (`--extend`); falls back to mirroring where macOS doesn't allow virtual displays.
- **Sound only on TV:** mutes the Mac's speakers while mirroring and restores them afterwards, even after a crash.
- The Mac no longer sleeps while mirroring.
- Reconnect to the last display on launch; global shortcut Ctrl+Opt+Cmd+M to start/stop.
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
- Wi-Fi Display RTSP source (M1-M8, keep-alives, IDR requests, pause/resume)
- Capability negotiation: 1080p30 -> 720p30 -> 640x480 by sink support and H.264 level
- Screen capture with ScreenCaptureKit, including system audio; choice of display
- H.264 Constrained Baseline (VideoToolbox), AAC-LC or LPCM audio
- MPEG-2 TS muxer and RTP (payload type 33) transport
- Menu bar app: discovery, connect by IP, resolution/bitrate/audio/display settings, test pattern, open at login, update check
- CLI: `list`, `connect`, `displays`, `doctor`, `--test-pattern`, `--dump-ts`, full protocol logging
- Auto-reconnect when a working session drops
- Discovery that keeps working with a VPN connected
- Mock sink (`tools/mock_sink.py`) and end-to-end test (`tools/e2e.sh`)
- Universal (Apple silicon + Intel) app, DMG, zip and Homebrew cask, built by GitHub Actions
