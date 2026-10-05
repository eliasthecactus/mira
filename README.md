# Mira

Screen mirroring from macOS to TVs and display adapters over your normal Wi-Fi network:

- **Miracast over Infrastructure** ([MS-MICE]): the **Microsoft 4K Wireless Display Adapter**, Windows PCs, Surface Hub
- **Google Cast**: **Chromecast**, **Google TV**, and TVs with *Chromecast built-in* (Sony, Philips, TCL, Hisense, ...), using the same real-time mirroring protocol as Chrome's "Cast screen"
- **DLNA** (experimental): the built-in media player of most smart TVs (Samsung, LG, ...), with a few seconds of delay

```
Mac --TCP 7250--> adapter      SOURCE_READY  ("I'm ready, connect to my port 7236")
Mac <--TCP 7236-- adapter      RTSP/WFD handshake (M1-M7), driven by the Mac
Mac --UDP RTP---> adapter      MPEG-2 TS: H.264 Constrained Baseline + AAC/LPCM
```

> **Built with AI:** Claude Opus 5.5 (Anthropic) was used heavily to build this project: protocol research, code, tests and documentation.

> **Status:** every protocol works end to end against local mock receivers (Miracast, Google Cast, DLNA), and the streams decode cleanly in ffmpeg. Google Cast has also worked on a real hotel TV; Miracast and DLNA are **not tested on real hardware yet**. See [Testing with a real adapter](#testing-with-a-real-adapter).

---

## Which display?

| Display | Protocol | Works with Mira? |
|---|---|---|
| **Microsoft 4K Wireless Display Adapter**, Windows PC, Surface Hub | Miracast over Wi-Fi | **Yes** (details below), lowest delay (~150-200 ms) |
| **Chromecast** (incl. with Google TV, 4K, Ultra), **Google TV / Android TV**, TVs with **Chromecast built-in** | Google Cast | **Yes**, ~250 ms delay, up to 4K with HEVC where the device supports it |
| **Samsung** (2018+), **LG** (2019+), Sony, Vizio, ... with **AirPlay 2**, Apple TV | AirPlay | Use macOS's own **Screen Mirroring** (Control Center); it's built in and better than anything Mira could do. Mira lists these TVs with a *How?* button that explains it |
| **Hotel and venue TVs** ("scan the code to cast") | Google Cast behind a gateway | **Yes**, after pairing the Mac with the room, see [Hotel and venue TVs](#hotel-and-venue-tvs) |
| Other smart TVs (older Samsung and LG, Philips, Panasonic, ...) | DLNA | **Experimental:** the TV plays Mira's stream in its media player, with 2-5 s of delay. Fine for presentations and video, not for typing. Not every TV plays live streams |
| The "Screen Mirroring" / "Screen Share" menu of Samsung and LG TVs, Fire TV, Roku | Miracast over Wi-Fi Direct | **No.** That needs a direct Wi-Fi link that macOS doesn't offer to apps |

Mira finds all of them on its own (`mira list` or the menu). To connect by IP, Mira checks which protocol the device speaks.

### Which Miracast adapter?

| Adapter | Works with Mira? |
|---|---|
| **Microsoft 4K Wireless Display Adapter** (2019) | **Yes, in principle.** It supports Miracast over Wi-Fi once joined to your network |
| Microsoft Wireless Display Adapter (2015, "V2") and older | **No.** These only do Wi-Fi Direct, which macOS can't speak |
| **A Windows 10/11 PC** ("Projecting to this PC") | **Should work.** Microsoft documents Windows as a receiver for this exact protocol. The quickest real-world test, see [below](#testing-with-a-windows-pc-no-adapter-needed) |
| Surface Hub, LG webOS TVs and other MICE receivers | Should work (same protocol), untested |

Check the label or the box. Microsoft's own support page says only the 4K model supports "Miracast over Wi-Fi".

### Testing with a Windows PC (no adapter needed)

A Windows PC can be the receiver. It's the same protocol, Microsoft's own implementation, and it supports PIN pairing and encryption too.

1. **Windows 11:** Settings -> System -> Optional features -> *View features* -> add **Wireless Display**. (Windows 10 1809+: Settings -> Apps -> Optional features -> *Add a feature* -> **Wireless Display**.)
2. Settings -> System -> **Projecting to this PC**:
   - *Some Windows and Android devices can project to this PC when you say it's OK* -> **Available everywhere on secure networks**
   - *Ask to project to this PC* -> **First time only** (Windows asks you to allow the Mac on the first connection: click **Allow** on the PC)
   - *Require PIN for pairing* -> **Never** to start with. Try **First time** later to test Mira's PIN pairing.
3. Make sure the PC's network is set to **Private** (Settings -> Network & internet -> your network -> *Private network*). Windows only allows projection on private networks.
4. Open the **Wireless Display** app on the PC (Windows waits for connections while it's open).
5. On the Mac, with both on the same network:
   ```bash
   mira list                                          # the PC should appear under its name
   mira connect "<PC name>" --test-pattern --verbose  # colour bars + beep on the PC
   mira connect "<PC name>"                           # your screen
   ```

If the PC never appears, connect by its IP (`ipconfig` on the PC). If it says *Sink did not connect back*, check that you clicked **Allow** on the PC within 30 seconds, and that the Mac's firewall allows Mira (`mira doctor`).

## One-time adapter setup (needs a Windows PC once)

The adapter has to join your Wi-Fi network first. That can only be done with Microsoft's app.

1. Plug the adapter into the TV (HDMI + USB power) and select that HDMI input.
2. On a **Windows 10/11 PC**, connect to the adapter the normal way (`Win + K`).
3. Install **Microsoft Wireless Display Adapter** from the Microsoft Store and open it while connected.
4. **Update the firmware** if the app offers it.
5. In the app's network/Wi-Fi settings, connect the adapter to your Wi-Fi.
   Microsoft's requirements:
   - **5 GHz** network
   - **WPA, WPA2 or WPA3 Personal** (no enterprise/802.1X, no captive portal, no proxy)
   - your Mac on the **same network and subnet**, with no "client isolation" (guest networks usually block device-to-device traffic)
6. A PIN or pairing option in the app is fine either way. Mira supports PIN pairing (see [Security](#security)), but connecting without one is simpler.

After that the Windows PC isn't needed any more.

## Install

Download the latest **Mira-*.dmg** from [Releases](https://github.com/eliasthecactus/mira/releases), open it and drag **Mira** into **Applications**. Requires macOS 13 Ventura or newer, on Apple silicon or Intel.

Releases are currently **not notarized** (that needs a paid Apple Developer ID), so macOS blocks the first launch:
open Mira once, then go to **System Settings -> Privacy & Security -> Open Anyway**.
Or run `xattr -dr com.apple.quarantine /Applications/Mira.app` once.

Mira lives in the **menu bar** (it has no Dock icon). On first launch:

| macOS asks for | Why | If you said no |
|---|---|---|
| **Local Network** | to find adapters and talk to them | System Settings -> Privacy & Security -> Local Network -> enable Mira. *Without it the display list just stays empty, because macOS reports no error.* |
| **Screen & System Audio Recording** (when you first mirror) | to capture the screen and sound | System Settings -> Privacy & Security -> Screen & System Audio Recording -> enable Mira, then quit and reopen it. |
| **Incoming connections** (firewall, if on) | the adapter connects *into* your Mac on TCP 7236 | System Settings -> Network -> Firewall -> Options -> allow Mira. |

Then click the menu bar icon, pick your display and click **Mirror**. If the adapter isn't listed, type its IP address. You can find it in your router's device list.

**Command line:** the same binary is a CLI. It's handy for diagnosing a new setup because it logs everything:

```bash
sudo ln -s /Applications/Mira.app/Contents/MacOS/Mira /usr/local/bin/mira   # optional
mira doctor                          # checks permissions, firewall, ports, network
mira list                            # find adapters on the network
mira connect 192.168.1.42            # mirror the screen (Ctrl-C to stop)
mira connect "Living Room"           # ...or by (part of) its name
mira connect 192.168.1.42 --test-pattern --verbose
mira displays                        # pick a screen with --display <n>
mira windows                         # apps and windows for --app / --window
mira connect <ip> --app Keynote      # share only Keynote
mira diagnose                        # diagnostics zip for a bug report
mira update                          # install the newest release
mira help                            # all options
```

### Settings

| Setting | Default | Notes |
|---|---|---|
| Share | Entire screen | or **one app** (all its windows; everything else, including notifications, stays black) or **one window** (even when covered). Switches live without reconnecting. `--app <name>`, `--window <title>`, list with `mira windows` |
| Mirror / Extend | Mirror | **Extend** makes the TV a second screen instead of a copy (`--extend`), see below |
| Display | main display | which screen to mirror: menu or `--display <n>` |
| Resolution | Best | best of 1080p30 / 720p30 the display supports. **4K** (3840x2160) if the display offers it (Miracast 2 or Microsoft's extension), else 1080p; needs ~25 Mbit/s of Wi-Fi (`--resolution 4k`) |
| Codec | Auto | H.264 up to 1080p (lowest delay, every display has it); **HEVC (H.265)** for 4K when the display supports it. `--codec h264` / `--codec hevc` to prefer one; Mira falls back to whatever the display can decode. HEVC needs a Mac from 2017 or later |
| Allow TV input | off | a keyboard, mouse or touch screen at the TV controls the Mac (UIBC), see [Input from the TV](#input-from-the-tv) (`--remote-input`) |
| 60 fps | off | smoother motion if the display supports 60 fps (`--fps 60`) |
| Low latency | off | about 100 ms instead of 200 ms: smaller buffer, LPCM audio, low-latency encoder. Can stutter on weak Wi-Fi (`--low-latency`) |
| Quality | Auto | adapts the bitrate to your Wi-Fi (backs off on packet loss or congestion, up to 12 Mbit/s); pick a number to fix it (`--bitrate 6`, `--max-bitrate 16`) |
| Audio | on | AAC if the adapter supports it, else LPCM; `--audio-codec lpcm` to force |
| Sound only on TV | on | mutes the Mac's speakers while mirroring so you don't hear everything twice; restored afterwards, even after a crash (`--keep-mac-audio` to turn off) |
| Security | Auto | see [Security](#security) (`--security`, `--pin`) |
| Reconnect on launch | off | reconnect to the last display when Mira starts |
| Latency buffer | 200 ms (AAC), 150 ms (LPCM), 120 ms (no audio) | `--delay <ms>`; raise it if audio crackles |

**Keyboard shortcuts:** Ctrl+Opt+Cmd+M starts mirroring to the last display, or stops it. Ctrl+Opt+Cmd+P **pauses the screen**: the TV keeps showing the last frame (or black, per setting), audio goes silent, and your Mac's screen is private, e.g. while typing a password. Press it again to resume. In the CLI, type `p` + Enter (`b` for black), or send `SIGUSR1`. While mirroring, the Mac doesn't go to sleep.

**Updates:** Mira checks GitHub once a day. When a new version is out, the menu shows it, and *Install and Restart* downloads it, verifies its SHA-256 checksum and signature, replaces the app (the old one goes to the Trash) and restarts. CLI: `mira update` (`--check` to only look).

**Diagnostics:** *Diagnostics* in the menu (or `mira diagnose`) saves a zip to your Desktop with the log, `mira doctor` output, system, display and network info, settings and recent crash reports. Attach it to a GitHub issue. It contains IP addresses and device names from your network, so have a look first.

### Extend: the TV as a second screen

In Extend mode Mira creates a virtual monitor the size of the stream, so macOS treats the TV as another screen: drag windows onto it, use it for presenter view. Arrange it in System Settings -> Displays like any monitor.

macOS has no public API for virtual monitors. Mira uses the private CoreGraphics one that display utilities such as BetterDisplay and DeskPad use. Mira checks that the virtual display really switched on. If it didn't, Mira mirrors instead and says so (`Mira doctor` tells you up front). On the macOS 27 build used for development it doesn't switch on, so Extend mode has only been exercised up to that fallback.

### Input from the TV

Some receivers can send input back to the Mac: Windows' *Project to this PC* forwards the PC's keyboard, mouse and touch screen, and touch displays send taps. Mira supports both Wi-Fi Display input formats: *generic* events (touch, mouse, ASCII keys, scrolling) and *HID* reports (real USB/Bluetooth keyboards, mice and touch screens, including arrow and function keys and modifiers). Touch becomes a click or drag, the Windows key becomes Command.

It is **off by default**: anyone at the TV can then use your Mac. Turn on *Allow TV input* (or `--remote-input`) and give Mira the Accessibility permission (System Settings -> Privacy & Security -> Accessibility); macOS silently drops the events without it, and `mira doctor` tells you. Input is ignored while the screen is paused, and accepted only from the display Mira is connected to. The display can switch input off at any time. Nothing you type is logged.

Whether a display offers input at all depends on the display: the Microsoft 4K adapter probably doesn't (it has no input ports). The log says "The display does not offer input back to the Mac" in that case.

### Google Cast (Chromecast, Google TV)

Mira speaks Cast Streaming, the protocol Chrome uses for "Cast screen": it starts the TV's built-in mirroring receiver and sends an encrypted real-time stream (AES-128 per frame) that the TV acknowledges frame by frame; lost packets are resent. Video is H.264, or HEVC for 4K on devices that support it (Chromecast with Google TV 4K, Google TV Streamer); audio is Opus. Delay is about 250 ms (150 ms with *Low latency*; `--delay <ms>` sets it).

Nothing to set up: the Chromecast appears in Mira's list like any other display. Mira stops the mirroring app on the TV when you stop, and the session ends if someone stops it on the TV. Input back from the TV isn't available with Cast.

### Hotel and venue TVs

Many hotels put their TVs behind a casting system: the TV shows a code or a QR code, and only devices that "paired" with it may cast. The link in the QR code (like `http://172.20.0.8/pair?pairCode=7F6GY`) has to be opened **on the Mac**; opening it on your phone pairs the phone. Mira does this for you:

- When a TV refuses the connection because the Mac isn't paired, Mira asks for the code right away. You can also click **Pair TV** in the menu.
- Type the **code** shown on the TV, paste the **link**, or click **Scan QR Code...** and hold the camera (or your iPhone as a Continuity Camera, which reads codes across a room much better) toward the TV.
- Mira opens the link itself, or finds the pairing form on the system's web page and fills in the code. If the page wants a person (accepting terms, a button), Mira opens it in your browser; finish it there, and Mira connects by itself as soon as the TV lets the Mac in.
- CLI: `mira connect <ip> --cast --port <port> --pair <code or link>` (`mira list` shows the address and port, marked as a hotel casting system).

Tested for real in a hotel (pairing by hand, then mirroring); the automatic pairing is tested against a mock hotel system with link, form and consent pages.

### Smart TVs over DLNA (experimental)

Most smart TVs have a DLNA media player that can play a video stream from the network. Mira serves your screen as a live MPEG-TS stream over HTTP and asks the TV to play it. That works with TVs that can't do anything better, but the TV buffers: expect **2-5 seconds of delay**. Good for slides and videos, not for typing or games.

- Samsung TVs from 2018 and LG TVs from 2019 on usually also support **AirPlay 2**: use macOS's Screen Mirroring instead (Control Center), it's faster.
- The TV must be allowed to fetch from the Mac: the macOS firewall must let Mira accept incoming connections (`mira doctor`).
- If the TV isn't found (some networks block the SSDP discovery), connect with its description URL: `mira connect <ip> --dlna-url http://<ip>:<port>/<path>.xml` (shown by UPnP tools like `upnp-inspector`, or in your router).
- Not every TV plays live streams. If the TV shows an error or nothing at all, it's that.

### Security

[MS-MICE] lets the *sender* choose how a session is protected. A display that follows the spec must accept a plain connection, so that's what Mira tries first:

| Setting | What happens |
|---|---|
| **Auto** (default) | plain connection; if the display doesn't answer within 10 s, Mira retries with PIN pairing and asks for the PIN shown on the TV |
| Off | plain connection only |
| Encrypted | DTLS 1.2 handshake over the MICE channel, then every RTP packet is encrypted |
| PIN | as Encrypted, plus the TV shows a PIN that you type on the Mac (dialog, or `--pin 12345678` in the CLI) |

The message flow, the PIN hash (checked against the spec's test vectors) and DTLS follow the spec exactly. The spec doesn't say *how* data is protected with the DTLS key. Mira sends each protected message and RTP packet as a DTLS application-data record, which is what a DTLS stack produces when asked to encrypt. This works against the bundled mock display (OpenSSL) but is an educated guess for real hardware. The log shows every handshake step, so the first test with a real adapter will confirm it.

## Build from source

Requires Xcode 16+ (Swift 5.9+).

```bash
make build        # debug build -> .build/debug/Mira
make test         # unit tests
make e2e          # full pipeline against the local mock sink, no hardware needed
make run          # menu bar app (debug)
make app          # build/Mira.app for this Mac
make dist         # universal DMG + zip + checksums + Homebrew cask in dist/
```

---

## Testing with a real adapter

Do these in order. Each step isolates one layer, so when something fails you'll know which one.

```bash
mira doctor                                                # 1. fix anything marked [warn]
mira list                                                  # 2. adapter should be listed
mira connect <ip> --test-pattern --no-audio --verbose      # 3. simplest stream
mira connect <ip> --test-pattern --verbose                 # 4. + audio (beep each second)
mira connect <ip>                                          # 5. real screen + audio
mira connect <ip> --resolution 4k --probe-wfd2 --verbose   # 6. 4K / HEVC, logs everything the adapter offers
mira connect <ip> --remote-input                           # 7. only if the display offers input back
```

For a **Chromecast** or **Google TV**, the same steps work (Mira detects the protocol): `mira connect <ip> --cast --test-pattern --verbose`, then `mira connect <ip> --cast`, then `--resolution 4k` on a 4K model. For a **DLNA TV**: `mira connect <ip> --dlna --test-pattern --verbose`. The log shows every message exchanged.

What success looks like at step 3:

```
[MICE] -> SOURCE_READY
[RTSP] Sink connected from 192.168.1.42          <- the adapter connected back (firewall OK)
[RTSP] <- 200 OK ... M1 / M3 / M4 / M5              <- capability negotiation
[RTSP] Sink H.264 (wfd_video_formats) profile ..., CEA: ...   <- what the adapter supports
[RTSP] Chose 1920x1080p30 H.264 Constrained Baseline ...       <- what Mira picked
[RTSP] <- SETUP / PLAY
[Mira] Mirroring to ... at 1920x1080p30
```

The TV should show colour bars with a moving white line and a running frame counter.

### If it fails: where and why

| Symptom in the log | Likely cause | Try |
|---|---|---|
| `list` finds nothing | Local Network permission off, adapter not on Wi-Fi, different subnet, or mDNS filtered | Check System Settings -> Privacy & Security -> Local Network. Re-check the setup steps. `dns-sd -B _display._tcp`. Connect by IP (find it in your router's DHCP list) |
| `Could not reach ... :7250 ... Connection refused` | not a 4K adapter, or infrastructure mode off | Check the model and firmware |
| `Sink did not connect back to the RTSP port within 15s` | **macOS firewall**, or the adapter wants PIN pairing | `Mira doctor`. Turn the firewall off briefly to test. Try `--security pin` |
| `The display rejected the PIN` | typo, or the PIN changed | Reconnect and type the PIN currently on the TV |
| `DTLS handshake ... failed` | the adapter's DTLS doesn't match Mira's | Send the log; use `--security off` meanwhile |
| `Sink rejected M4 ...` | the chosen format was refused (Mira already retried simpler ones) | `--legacy-formats`, `--resolution 720p`, then `--no-audio` |
| 4K or HEVC: handshake OK but black screen | the adapter mis-advertises Miracast 2 | `--codec h264`, or `--legacy-formats`; send the log |
| Handshake OK but black screen | the media stream isn't accepted | `--no-audio`, `--resolution 720p`, `--bitrate 4`. Check `--dump-ts out.ts` plays in `ffplay` |
| Picture stutters or freezes | Wi-Fi throughput or jitter | Auto quality should back off by itself (look for `[Bitrate]` lines); otherwise `--bitrate 4`, `--delay 300`, move closer to the router |
| Audio crackles or drops | audio arrives too late | `--delay 300`. Try `--audio-codec lpcm` |
| Handshake OK, no sound | adapter dislikes AAC | `--audio-codec lpcm` |

**Please send `~/Library/Logs/Mira/mira.log` from the first real test.** It contains every MICE/RTSP message exchanged with the adapter, including its exact capabilities. That's the information needed to fix anything adapter-specific.

### Recording what the adapter does (optional, very useful)

```bash
sudo tcpdump -i en0 -w mira-adapter.pcap host <adapter-ip>   # in a second terminal while connecting
```

If you have a Windows PC, also capture a session from Windows -> adapter in the same way. A side-by-side comparison of the RTSP exchange shows exactly what the adapter expects.

---

## Testing without hardware

`tools/mock_sink.py` is a scripted MICE sink. It listens on 7250, connects back for RTSP, plays the sink side of M1-M8, and checks every RTP/TS packet (sequence numbers, continuity counters, PAT/PMT, PCR interval, and whether each PES arrives before its presentation time).

```bash
make e2e                                               # automated: handshake + stream validation + ffmpeg decode
MIRA_ARGS="" tools/e2e.sh                              # same, capturing the real screen
python3 tools/mock_sink.py --play                      # interactive: watch the stream in ffplay
.build/debug/Mira connect 127.0.0.1                    # ...in a second terminal
python3 tools/mock_sink.py --advertise "Fake TV"       # appears in `Mira list` and the menu bar app
python3 tools/mock_sink.py --loss 10                   # drop 10 % of packets, report it via RTCP -> watch Mira back off
python3 tools/mock_sink.py --wfd2 hevc                 # a Miracast 2 display with HEVC (also --wfdx hevc, --wfd2 windows)
python3 tools/mock_sink.py --uibc                      # offers input back and sends a few harmless events
python3 tools/mock_sink.py --help                      # --no-audio, --no-m2, --strict-m3, --expect-codec, --idr-at, ...

# Security modes need pyOpenSSL (a DTLS server):
python3 -m venv .venv && .venv/bin/pip install pyopenssl cryptography
.venv/bin/python tools/mock_sink.py --security pin --pin 12345678   # ignores plain connections, shows a PIN
MIRA_ARGS="--test-pattern --security pin --pin 12345678" tools/e2e.sh --security pin --pin 12345678
```

Google Cast and DLNA have their own mock receivers and end-to-end scripts:

```bash
tools/e2e_cast.sh                                      # mock Chromecast: TLS control, OFFER/ANSWER, encrypted RTP, ACK/NACK
tools/e2e_cast.sh --loss 8                             # drops 8 % of packets; checks they are all resent
tools/e2e_cast.sh --pli-at 3 --video-codecs hevc,h264  # picture loss -> key frame; HEVC
tools/e2e_dlna.sh                                      # mock smart TV: SSDP, SOAP, live HTTP MPEG-TS, TV stops playback
tools/e2e_pairing.sh form                              # mock hotel casting system: pair (link, form, consent, consent-user), then cast
.venv/bin/python tools/mock_cast.py --advertise "Fake Chromecast"   # shows up in Mira's list
```

The mock sink is written from the same specs as Mira, so it can't catch a shared misreading of them. ffmpeg's independent decode check and the real adapter cover that.

## How it works

| Layer | File | Notes |
|---|---|---|
| Discovery | `Discovery/DeviceBrowser.swift`, `DLNA/SSDPDiscovery.swift` | DNS-SD `_display._tcp` (Miracast, TXT `container_id`) and `_googlecast._tcp` (TXT `fn`, `md`, `ca`), resolved per interface (works with a VPN connected); SSDP for DLNA renderers |
| Google Cast | `Cast/CastChannel.swift`, `CastSession.swift`, `CastOffer.swift` | TLS to port 8009, Cast v2 protobuf framing, heartbeat; LAUNCH of the mirroring receiver `0F5096E8`, OFFER/ANSWER (as Chrome sends it) |
| Cast Streaming | `Cast/CastStreamSender.swift`, `CastTransport.swift` | Cast RTP (frame and packet IDs), AES-128-CTR per frame, RTCP sender reports, ACK/NACK retransmission, kickstart, picture-loss key frames ([openscreen] is the reference) |
| Hotel pairing | `Cast/CastPairing.swift`, `UI/QRScannerWindow.swift` | detects gateways (Cast on a port other than 8009 that refuses), pairs with a link or a code (HTML form discovery, known link patterns, browser hand-off), reads QR codes with AVFoundation + Vision |
| DLNA | `DLNA/DLNARenderer.swift`, `HTTPStreamTransport.swift` | UPnP AVTransport (SetAVTransportURI, Play, Stop, GetTransportInfo), live MPEG-TS over HTTP with DLNA streaming headers; viewers start at a key frame |
| MICE | `Session/MICEMessage.swift`, `MICEClient.swift` | SOURCE_READY / STOP_PROJECTION, SESSION_REQUEST / PIN challenge; friendly name is UTF-16LE with BOM, as Windows and GNOME send it |
| Security | `Session/DTLSTunnel.swift` | Network.framework DTLS 1.2 client behind a loopback relay, so its records can travel inside MICE messages and RTP |
| RTSP/WFD | `Session/WFDSession.swift`, `WFDNegotiation.swift` | Mac is the RTSP server; M1-M8, M15, M16 keep-alive every 25 s, IDR requests, PAUSE/PLAY. Formats from `wfd_video_formats` (Miracast 1), `wfd2_video_formats` (Miracast 2: H.264 + HEVC, 4K) and Microsoft's `wfdx_video_formats`; each has its own 4K table numbering. Falls back to simpler requests if a display rejects one |
| Capture | `Capture/ScreenCapturer.swift` | ScreenCaptureKit video + system audio, letterboxed to 16:9 |
| Video | `Encoder/VideoEncoder.swift`, `H264Bitstream.swift`, `HEVCBitstream.swift` | VideoToolbox H.264 (Constrained Baseline / Constrained High, CAVLC as WFD requires) or HEVC Main, no B-frames, IDR every 2 s or on request, AUD + parameter sets per keyframe |
| Input | `Input/UIBCServer.swift`, `UIBCProtocol.swift`, `HIDDescriptor.swift`, `UIBCTranslator.swift`, `InputInjector.swift` | UIBC TCP server, generic and HID input (HID report descriptor parser), mapped back through the capture's letterbox and posted as macOS events |
| Audio | `Encoder/CompressedAudioEncoder.swift`, `LPCMEncoder.swift` | AAC-LC 48 kHz stereo 128 kbit/s (ADTS, or raw for Cast), Opus (Cast), or WFD LPCM 16-bit big-endian |
| Mux | `Mux/MPEGTSMuxer.swift` | WFD PIDs (PMT 0x100, video 0x1011, audio 0x1100), stream type 0x1B (H.264) or 0x24 (HEVC), PCR on video, PAT/PMT every 100 ms |
| Transport | `RTP/RTPMP2TPacketizer.swift`, `RTPSender.swift` | RTP payload type 33, 7 TS packets per datagram |
| Quality | `RTP/BitrateController.swift`, `RTCPSender.swift` | AIMD bitrate from RTCP receiver reports, send backlog and repeated keyframe requests |
| System | `Util/SystemIntegration.swift`, `CVirtualDisplay/` | sleep prevention, speaker mute, virtual display, global shortcut |
| Pipeline | `MediaPipeline.swift`, `MediaTransport.swift`, `WFDTransport.swift` | capture and encoding shared by all protocols; a constant-rate frame pump (re-sends the last frame on a static screen); each protocol is a transport (Miracast: PTS = capture + buffer, PCR backstop on audio) |

References: [MS-MICE], [MS-WFDPE] (Microsoft's Wi-Fi Display extensions), the Miracast (Wi-Fi Display) specification v2.3, Android's open-source Wi-Fi Display source (LPCM layout), ISO/IEC 13818-1 (MPEG-TS), RFC 2250 (MPEG-TS over RTP), [openscreen] (Google's open-source Cast implementation and its streaming protocol document), the UPnP AVTransport and DLNA guidelines, and [GNOME Network Displays], an open-source MICE source that was invaluable for byte-level details.

## Releasing

1. Add a `## [x.y.z]` section to `CHANGELOG.md` and commit.
2. `make release VERSION=x.y.z` bumps `Support/Info.plist`, commits and tags.
3. `git push && git push origin vx.y.z`. GitHub Actions tests, builds the universal app, and publishes a release with the DMG, zip, checksums and Homebrew cask. Versions with a suffix (`-beta.1`) become pre-releases.

**Signed + notarized releases:** add the repository secrets `MACOS_CERTIFICATE` (base64 Developer ID Application `.p12`), `MACOS_CERTIFICATE_PWD`, `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_PASSWORD`. The workflow then signs with the Developer ID and notarizes automatically, and the Gatekeeper step above goes away.

**Homebrew:** each release includes `mira.rb`. Put it in a tap repo (`eliasthecactus/homebrew-tap`, file `Casks/mira.rb`) and users can `brew install --cask eliasthecactus/tap/mira`.

## Not implemented

- **HDCP**, and it can't be. HDCP 2.x over Miracast needs a device key set and a certificate signed by Digital Content Protection LLC, plus the secret `lc128` constant, all of which are only issued to licensed companies, together with robustness rules that require hardware key protection. No open-source Miracast implementation has it. It also wouldn't help: HDCP only matters for DRM-protected video (Netflix and the like), and macOS never lets screen capture see that content anyway. Everything else mirrors normally, and the spec explicitly allows a source to stream without HDCP. Mira logs it when a display offers HDCP and carries on.
- **Miracast over Wi-Fi Direct** (the "Screen Mirroring" menu of Samsung/LG TVs, Fire TV, Roku, the older Microsoft adapter): the Mac would have to open a direct Wi-Fi link to the TV, and macOS gives apps no way to do that.
- **Sending to AirPlay receivers**: macOS does that itself, and the protocol needs Apple's device authentication.
- Input back from Google Cast receivers (a draft in openscreen, not used by current devices).
- Miracast 2 extras that don't apply to screen mirroring: direct streaming of video files without re-encoding, 10-bit and 4:4:4 HEVC, TCP transport, auxiliary streams.
- Notarized builds out of the box. Supported by the release workflow once Developer ID secrets are added.

[MS-MICE]: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-mice/940d808c-97f8-418e-a8a9-c471dc0d21bb
[GNOME Network Displays]: https://gitlab.gnome.org/GNOME/gnome-network-displays
[MS-WFDPE]: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-wfdpe/
[openscreen]: https://chromium.googlesource.com/openscreen/

## License

MIT - see [LICENSE](LICENSE).
