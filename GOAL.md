# Mira

**macOS screen mirroring to Microsoft Wireless Display Adapter (and any Miracast receiver) — built from first principles.**

---

## Problem

macOS has no native Miracast support. The only working solution is AirParrot ($19.99), which reverse-engineering confirms implements the full WFD/Miracast stack from scratch over infrastructure Wi-Fi (no Wi-Fi Direct needed). Mira does the same thing as a free, open, native macOS app.

---

## Core Insight (from AirParrot RE)

The Microsoft Wireless Display Adapter supports **Miracast over Infrastructure**: when both Mac and adapter are on the same Wi-Fi network, the Miracast RTSP control session and RTP media stream run over plain TCP/UDP sockets — no Wi-Fi Direct, no special kernel drivers, no hardware gap. macOS handles this perfectly. The only missing piece was an implementation.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Mira.app (macOS, Swift + C)                                    │
│                                                                 │
│  ┌──────────────┐   ┌──────────────┐   ┌─────────────────────┐ │
│  │   Discovery  │   │   Capture    │   │   Session Manager   │ │
│  │  (DNS-SD /   │   │ (ScreenCap-  │   │  (WFD state machine │ │
│  │   mDNS)      │   │  tureKit +   │   │   RTSP signaling)   │ │
│  └──────┬───────┘   │  AVAudio)    │   └──────────┬──────────┘ │
│         │           └──────┬───────┘              │            │
│         │                  │                      │            │
│         ▼                  ▼                      ▼            │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    Encoder Pipeline                      │  │
│  │   VideoToolbox H.264  +  AAC (AudioToolbox)              │  │
│  └──────────────────────────────────┬───────────────────────┘  │
│                                     │                           │
│                                     ▼                           │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                   RTP/SRTP Sender                        │  │
│  │   packetize → SRTP encrypt → UDP send                    │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │ UDP (port negotiated via RTSP)
                              ▼
               Microsoft Wireless Display Adapter
               (or any Miracast-over-infrastructure receiver)
```

---

## Components

### 1. Discovery (`Sources/Discovery/`)

**Goal:** Find Miracast receivers on the local network.

- Use `Network.framework` DNS-SD (`NWBrowser`) to browse `_miracast._tcp` and `_wfd._tcp` services.
- Fall back to raw mDNS UDP on port 5353 if needed (some adapters use non-standard service types).
- Parse TXT records: device name, model, supported WFD spec version.
- Emit a `MiracastDevice` struct: `{ name, ipAddress, port (default 7236), wfdVersion }`.
- UI: show discovered devices in a menu bar popover list, refresh every 5s.

**Key references:**
- WFD spec: Wi-Fi Display Technical Specification v2.1 (Wi-Fi Alliance)
- mDNS service type: `_wfd._tcp` (some adapters) or discovered via `_display._tcp`

---

### 2. WFD Session / RTSP Signaling (`Sources/Session/`)

**Goal:** Implement the Wi-Fi Display RTSP handshake to establish a mirroring session.

Miracast uses a custom RTSP dialect (WFD). The full handshake over infrastructure:

```
Mac (Source)                          Adapter (Sink)
     │                                      │
     │──── TCP connect → port 7236 ────────▶│
     │                                      │
     │◀─── OPTIONS * RTSP/1.0 ─────────────│  (sink initiates)
     │──── 200 OK, Public: OPTIONS, ... ──▶│
     │                                      │
     │◀─── GET_PARAMETER rtsp://... ───────│  (sink requests caps)
     │     wfd-audio-codecs                 │
     │     wfd-video-formats                │
     │     wfd-client-rtp-ports             │
     │──── 200 OK  ─────────────────────── │  (source responds with caps)
     │     wfd-audio-codecs: AAC 00000001   │
     │     wfd-video-formats: ...           │
     │     wfd-client-rtp-ports: RTP/AVP/  │
     │       UDP;unicast;1990 0 mode=play   │
     │                                      │
     │──── SET_PARAMETER rtsp://... ───────▶│  (source triggers)
     │     wfd-trigger-method: SETUP        │
     │◀─── 200 OK ─────────────────────────│
     │                                      │
     │◀─── SETUP rtsp://.../streamid=0 ───│
     │──── 200 OK, Session: <id> ──────────▶│
     │                                      │
     │◀─── PLAY rtsp://... ────────────────│
     │──── 200 OK ─────────────────────────▶│
     │                                      │
     │════ RTP video stream (UDP) ══════════▶│
     │════ RTP audio stream (UDP) ══════════▶│
     │                                      │
     │  (keepalive every 30s via GET_PARAMETER / SET_PARAMETER)
```

**Implementation:**
- Plain TCP socket (port 7236), line-delimited RTSP/1.0 text protocol.
- Parse/generate WFD capability headers (`wfd-video-formats`, `wfd-audio-codecs`).
- State machine: `idle → connecting → negotiating → streaming → teardown`.
- Handle `wfd-uibc-capability` (user input back-channel) — skip for v1.
- Keepalive: respond to sink's periodic `GET_PARAMETER` with `200 OK`.
- On teardown: send `TEARDOWN` and close socket.

**WFD video format field (wfd-video-formats):**
```
native profile: CEA H264 CBP level 3.2
  codec:    H.264
  profile:  Constrained Baseline (CBP) or Main
  level:    3.1 (720p30), 3.2 (1080p30)
  latency:  0
  min-slice-size: 0
  slice-enc-params: 0
  frame-rate: 30fps
  resolution: 1280x720 or 1920x1080
```

---

### 3. Screen Capture (`Sources/Capture/`)

**Goal:** Grab the display as a stream of raw pixel buffers at 30fps.

- Use **ScreenCaptureKit** (`SCStream`) — available macOS 12.3+.
- Request `SCStreamConfiguration`: 1280×720 (or 1920×1080), 30fps, `pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`.
- Handle permission prompt (`SCShareableContent.getWithCompletionHandler`).
- Output: `CMSampleBuffer` frames passed directly to the encoder.
- For audio: `SCStream` can also capture system audio — use `capturesAudio = true` on `SCStreamConfiguration`, which eliminates needing a loopback driver.

**Note:** On macOS < 12.3, fall back to `CGDisplayStream` (deprecated but functional).

---

### 4. H.264 Encoder (`Sources/Encoder/`)

**Goal:** Encode raw frames to H.264 Annex B NAL units in real time.

- Use **VideoToolbox** `VTCompressionSession`.
- Settings for Miracast compatibility:
  ```
  kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Baseline_3_2
  kVTCompressionPropertyKey_RealTime: true
  kVTCompressionPropertyKey_AllowFrameReordering: false   // no B-frames
  kVTCompressionPropertyKey_MaxKeyFrameInterval: 90       // keyframe every 3s at 30fps
  kVTCompressionPropertyKey_ExpectedFrameRate: 30
  kVTCompressionPropertyKey_AverageBitRate: 4_000_000     // 4 Mbps (adjustable)
  kVTCompressionPropertyKey_DataRateLimits: [500_000, 1]  // 500KB per second burst
  ```
- Output: `CMSampleBuffer` with H.264 NAL units → convert to Annex B (replace length prefixes with `00 00 00 01` start codes) → pass to RTP packetizer.

**Audio:**
- Use **AudioToolbox** `AudioConverter` to encode PCM → AAC-LC.
- Sample rate: 44100 Hz, stereo, 128 kbps.
- Alternatively: LPCM (uncompressed) for lower latency, which Miracast also supports.

---

### 5. RTP Packetizer & SRTP Sender (`Sources/RTP/`)

**Goal:** Packetize encoded H.264/AAC into RTP packets and send over UDP with optional SRTP encryption.

**RTP (RFC 3550):**
- Video: payload type 33 (MP2T) or 97 (H264 dynamic), SSRC randomly chosen.
- H.264 packetization: RFC 6184 — single NAL unit packets for small NALUs, FU-A fragmentation for NALUs > MTU (1460 bytes).
- Timestamp: 90kHz clock for video, 44100Hz for audio.
- Sequence numbers: monotonically increasing per stream.

**SRTP (RFC 3711):**
- Key exchange: negotiated in RTSP SETUP via `Transport` header.
- Profile: `AES_128_CM_HMAC_SHA1_80` (most compatible).
- Use Apple's **Security.framework** or a lightweight C SRTP lib (libsrtp2).
- If the adapter doesn't require encryption (Microsoft adapter often doesn't in infrastructure mode), skip SRTP for v1.

**RTCP:**
- Send sender reports (SR) every second.
- Handle receiver reports (RR) for basic feedback.
- No complex adaptive bitrate for v1.

---

### 6. UI (`Sources/UI/`)

**Goal:** Minimal menu bar app.

- `NSStatusItem` in the menu bar with a display icon.
- Click → popover showing discovered devices.
- Each device: name + "Mirror" button.
- While mirroring: show a "Stop" button + simple stats (bitrate, fps).
- Preferences: resolution (720p / 1080p), bitrate slider (2–8 Mbps), audio on/off.
- No Dock icon (`LSUIElement = YES` in Info.plist).

---

## Project Structure

```
mira/
├── GOAL.md
├── README.md
├── .gitignore
├── Mira.xcodeproj/
├── Sources/
│   ├── App/
│   │   ├── AppDelegate.swift
│   │   ├── StatusBarController.swift
│   │   └── Info.plist
│   ├── Discovery/
│   │   ├── DeviceBrowser.swift       # NWBrowser DNS-SD
│   │   └── MiracastDevice.swift      # device model
│   ├── Session/
│   │   ├── WFDSession.swift          # RTSP TCP socket + state machine
│   │   ├── RTSPMessage.swift         # parse/generate RTSP messages
│   │   └── WFDCapabilities.swift     # encode/decode WFD header values
│   ├── Capture/
│   │   ├── ScreenCapturer.swift      # SCStream wrapper
│   │   └── AudioCapturer.swift       # SCStream audio output
│   ├── Encoder/
│   │   ├── H264Encoder.swift         # VTCompressionSession wrapper
│   │   ├── AACEncoder.swift          # AudioConverter wrapper
│   │   └── AnnexBConverter.swift     # AVCC → Annex B NAL conversion
│   ├── RTP/
│   │   ├── RTPPacketizer.swift       # H264 RFC 6184 packetization
│   │   ├── RTPSender.swift           # UDP socket sender
│   │   ├── SRTPContext.swift         # SRTP encrypt (libsrtp2 or Security.framework)
│   │   └── RTCPSender.swift          # sender reports
│   └── UI/
│       ├── DeviceListViewController.swift
│       ├── MirroringStatusView.swift
│       └── PreferencesViewController.swift
├── Tests/
│   ├── RTSPParserTests.swift
│   ├── WFDCapabilityTests.swift
│   ├── RTPPacketizerTests.swift
│   └── H264EncoderTests.swift
└── vendor/
    └── libsrtp2/                     # optional: C library for SRTP
```

---

## Build Phases

### Phase 1 — Discovery + RTSP Handshake (no video yet)
- [ ] Set up Xcode project (macOS 13+, Swift 5.9, no SwiftUI — AppKit menu bar app)
- [ ] Implement `DeviceBrowser` using `NWBrowser` for `_wfd._tcp` / `_miracast._tcp`
- [ ] Implement raw TCP socket connection to port 7236
- [ ] Parse incoming RTSP messages (method, headers, body)
- [ ] Implement WFD handshake state machine through PLAY
- [ ] Test: confirm successful session setup with Microsoft adapter (no video stream yet)

### Phase 2 — Screen Capture + H.264 Encoding
- [ ] Implement `ScreenCapturer` with ScreenCaptureKit, output `CMSampleBuffer` at 30fps
- [ ] Implement `H264Encoder` with VideoToolbox, confirm Baseline 3.2 output
- [ ] Implement `AnnexBConverter` (strip AVCC length prefixes, insert start codes)
- [ ] Implement `AACEncoder` via AudioConverter
- [ ] Unit test encoder output with a static test frame

### Phase 3 — RTP Streaming
- [ ] Implement `RTPPacketizer` for H.264 (single NAL + FU-A fragmentation)
- [ ] Implement `RTPSender` (UDP socket, configurable target IP/port from RTSP SETUP)
- [ ] Implement `RTCPSender` (sender reports every 1s)
- [ ] Wire capture → encode → packetize → send pipeline
- [ ] Test: send RTP stream to a Miracast sink, confirm picture appears

### Phase 4 — SRTP + Stability
- [ ] Integrate libsrtp2 (or evaluate if Microsoft adapter requires it in infrastructure mode)
- [ ] Implement `SRTPContext` wrapping encrypt/decrypt
- [ ] Keepalive: handle sink's periodic `GET_PARAMETER` pings
- [ ] Teardown: clean shutdown on user request or network drop
- [ ] Reconnect: auto-reconnect if session drops

### Phase 5 — UI + Polish
- [ ] Menu bar status item + device popover
- [ ] Mirroring status view (fps, bitrate, latency indicator)
- [ ] Preferences (resolution, bitrate, audio toggle)
- [ ] Proper screen recording permission request flow
- [ ] App icon

### Phase 6 — Release
- [ ] Codesign + notarize (required for distribution outside App Store)
- [ ] README with setup instructions
- [ ] GitHub release (eliasfrehner/mira)

---

## Key Technical References

- **Wi-Fi Display Spec v2.1** — Wi-Fi Alliance (governs WFD RTSP dialect + capability format)
- **RFC 3550** — RTP: A Transport Protocol for Real-Time Applications
- **RFC 6184** — RTP Payload Format for H.264 Video (FU-A packetization)
- **RFC 3711** — SRTP
- **Apple VideoToolbox** — `VTCompressionSession` docs
- **ScreenCaptureKit** — `SCStream`, `SCStreamConfiguration`
- **libsrtp2** — https://github.com/cisco/libsrtp (MIT license)
- **AirParrot binary analysis** — confirmed RTSP flow, SDP format, mDNS discovery strategy, H.264 encoder settings

---

## Constraints & Decisions

| Decision | Rationale |
|---|---|
| Infrastructure mode only (no Wi-Fi Direct) | macOS has no Wi-Fi Direct driver; infrastructure mode works over regular Wi-Fi |
| ScreenCaptureKit (macOS 12.3+ minimum) | Eliminates need for kernel extension or `CGDisplayStream` |
| VideoToolbox H.264 (not x264) | Hardware-accelerated, low-latency, built into macOS |
| No B-frames, Baseline profile | Required by Miracast spec for low-latency display |
| Menu bar app, no Dock icon | Mirroring is a background utility, not a document app |
| Swift + C for SRTP | Swift for app logic, C (libsrtp2) for crypto correctness |
| Skip UIBC (input back-channel) | v1 scope: display only, no touch/keyboard feedback from sink |
