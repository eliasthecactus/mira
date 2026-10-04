# Mira

**macOS screen mirroring to the Microsoft 4K Wireless Display Adapter (and any Miracast-over-Infrastructure receiver), built from first principles.**

---

## Problem

macOS has no native Miracast support. Commercial tools such as AirParrot implement the Wi-Fi Display stack themselves over infrastructure Wi-Fi, so no Wi-Fi Direct is needed. Mira does the same as a free, open, native macOS app.

## Core insight

Microsoft's **Miracast over Infrastructure** ([MS-MICE]) runs the whole Miracast session over the normal LAN, using plain TCP/UDP sockets: no Wi-Fi Direct, no drivers. macOS can do all of it. Only receivers that implement MS-MICE work this way. Among Microsoft's adapters that is **only the 4K Wireless Display Adapter**, and only after it has been joined to the Wi-Fi network with Microsoft's app.

## Protocol (as implemented)

```
Mac (source)                                   Adapter (sink)
  │  mDNS: <name>._display._tcp → port 7250, TXT container_id
  │
  │  listen TCP 7236 (RTSP server)
  │── TCP connect :7250 ─────────────────────────▶│
  │── MICE SOURCE_READY {name, rtsp_port, id} ──▶│
  │◀──────────────── TCP connect :7236 ───────────│   sink connects *to us*
  │── M1 OPTIONS * (Require: org.wfa.wfd1.0) ───▶│
  │◀──────────────────────── M2 OPTIONS * ───────│
  │── M3 GET_PARAMETER (sink capabilities) ─────▶│
  │── M4 SET_PARAMETER (chosen format, URL) ────▶│
  │── M5 SET_PARAMETER wfd_trigger_method: SETUP▶│
  │◀──────────────── M6 SETUP (client_port) ─────│
  │◀──────────────── M7 PLAY ────────────────────│
  │══ RTP PT33: MPEG-2 TS (H.264 CBP + AAC) ════▶│   UDP
  │── M16 GET_PARAMETER keep-alive every 25 s ──▶│
  │◀──────── SET_PARAMETER wfd_idr_request ──────│   → force keyframe
  │── M5 trigger TEARDOWN / ◀── M8 TEARDOWN ─────│
  │── MICE STOP_PROJECTION ─────────────────────▶│
```

Byte-level details, PIDs and timing are documented in the source files and the README.

## Build phases

### Phase 1: Discovery + signalling ✅
- [x] `DeviceBrowser`: `_display._tcp` + TXT `container_id`, resolved without connecting to 7250
- [x] `MICEMessage`/`MICEClient`: SOURCE_READY, STOP_PROJECTION, UTF-16LE+BOM friendly name, stable 16-byte source ID
- [x] `WFDSession`: Mac as RTSP server, source-driven M1–M8, M16 keep-alive, PAUSE/PLAY, IDR requests, timeouts with diagnostics
- [x] `WFDNegotiation`: parse sink `wfd_video_formats`/`wfd_audio_codecs`/`wfd_client_rtp_ports`; choose 1080p30 → 720p30 → 640x480p60 by bitmap and level

### Phase 2: Capture + encoding ✅
- [x] ScreenCaptureKit video + system audio, excluding Mira's own windows
- [x] Constant-rate frame pump (static screens keep PCR and the decoder fed), PTS on an exact 1/fps grid
- [x] VideoToolbox H.264 Baseline at the negotiated level, CBP flags in SPS, IDR every 2 s or on request
- [x] AAC-LC 48 kHz stereo with ADTS
- [x] Test pattern + sync beep source (`--test-pattern`)

### Phase 3: Transport ✅
- [x] MPEG-2 TS muxer (WFD PIDs, PAT/PMT every 100 ms, PCR on video, AUD per access unit)
- [x] RTP payload type 33, 7 TS packets per datagram, RTCP SR when the sink gives an RTCP port

### Phase 4: Stability + tooling ✅
- [x] Auto-reconnect (3 tries) when a working session drops
- [x] `Mira doctor`: permissions, firewall, ports, interfaces
- [x] Full logging of every MICE/RTSP message to `~/Library/Logs/Mira/mira.log`, `--dump-ts`
- [x] `tools/mock_sink.py` + `tools/e2e.sh`: scripted sink with stream validation, plus ffmpeg decode check
- [x] Unit tests: MICE bytes, RTSP framing, negotiation, TS mux (incl. CC regression), RTP, ADTS, AAC timing

### Phase 5: UI ✅
- [x] Menu bar popover: discovered displays, connect by IP, resolution/bitrate/audio settings, status/errors, open log

### Phase 6: Distribution ✅
- [x] LPCM audio fallback (mandatory WFD format) + `--audio-codec`
- [x] Display picker, test-pattern toggle, open at login, update check, permission prompts in the app
- [x] DNS-SD discovery that works with a VPN connected; Local Network hints
- [x] App icon, universal (arm64 + x86_64) app bundle, DMG, zip, checksums, Homebrew cask (`scripts/package.sh`)
- [x] GitHub Actions: CI (build, tests, 3× e2e, package) and tag-triggered releases with optional Developer ID signing + notarization
- [x] MIT license, CHANGELOG, hardware-report issue template, `make release`

### Phase 7: Hardware validation ⏳ ← next
- [ ] Join the 4K adapter to Wi-Fi (Windows app) and run the README test-day checklist
- [ ] Fix whatever the real adapter disagrees with (send `mira.log`)
- [ ] Measure latency; tune the default buffer and bitrate
- [ ] Developer ID certificate → notarized releases (add the repository secrets)

### Later / maybe
- [ ] MICE DTLS stream encryption + PIN pairing (only if adapters require it)
- [ ] Extended desktop via virtual display
- [ ] UIBC input back-channel
- [ ] Adaptive bitrate from RTCP receiver reports

## Constraints & decisions

| Decision | Rationale |
|---|---|
| MS-MICE / infrastructure mode only | macOS has no Wi-Fi Direct; MICE needs only TCP/UDP |
| Mac is the RTSP server | Required by Wi-Fi Display (source = server) and MS-MICE (sink connects back) |
| MPEG-2 TS over RTP (PT 33) | Mandatory WFD media encapsulation; raw RFC 6184 H.264 is not understood by sinks |
| H.264 Constrained Baseline, no B-frames | Mandatory for every WFD sink; lowest latency |
| AAC 48 kHz stereo, else LPCM | AAC is compact; LPCM (private stream 1, Android layout) is the format every WFD sink must accept |
| 200 ms PTS delay with AAC, 150 ms LPCM, 120 ms video-only | AAC adds ~65 ms lookahead; measured headroom ≥110 ms locally |
| Re-encode the last frame on static screens | Keeps PCR flowing and avoids sink underflow |
| Swift only, no dependencies | Everything needed is in VideoToolbox/AudioToolbox/Network/ScreenCaptureKit |

[MS-MICE]: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-mice/940d808c-97f8-418e-a8a9-c471dc0d21bb
