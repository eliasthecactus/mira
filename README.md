# Mira

Screen mirroring from macOS to Miracast receivers — specifically the **Microsoft 4K Wireless Display Adapter** — over your normal Wi-Fi network, using Microsoft's *Miracast over Infrastructure* protocol ([MS-MICE]).

```
Mac ──TCP 7250──▶ adapter      SOURCE_READY  ("I'm ready, connect to my port 7236")
Mac ◀──TCP 7236── adapter      RTSP/WFD handshake (M1–M7), driven by the Mac
Mac ──UDP RTP───▶ adapter      MPEG-2 TS: H.264 Constrained Baseline + AAC/LPCM
```

> **Status:** the full pipeline works against a local mock sink, and the stream decodes cleanly in ffmpeg. It has **not been tested against a real adapter yet**. See [Testing with a real adapter](#testing-with-a-real-adapter).

---

## Which adapter?

| Adapter | Works with Mira? |
|---|---|
| **Microsoft 4K Wireless Display Adapter** (2019) | **Yes, in principle.** It supports Miracast over Wi-Fi once joined to your network |
| Microsoft Wireless Display Adapter (2015, "V2") and older | **No.** These only do Wi-Fi Direct, which macOS can't speak |
| Windows 10/11 PCs, Surface Hub, LG webOS TVs and other MICE receivers | Should work (same protocol), untested |

Check the label or the box. Microsoft's own support page says only the 4K model supports "Miracast over Wi-Fi".

## One-time adapter setup (needs a Windows PC or Xbox)

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
6. If the app has a PIN/pairing option, set it so **no PIN is required**. Mira doesn't implement PIN entry or encryption yet.

After that the Windows PC isn't needed any more.

## Install

Download the latest **Mira-*.dmg** from [Releases](https://github.com/eliasthecactus/mira/releases), open it and drag **Mira** into **Applications**. Requires macOS 13 Ventura or newer, on Apple silicon or Intel.

Releases are currently **not notarized** (that needs a paid Apple Developer ID), so macOS blocks the first launch:
open Mira once, then go to **System Settings → Privacy & Security → Open Anyway**.
Or run `xattr -dr com.apple.quarantine /Applications/Mira.app` once.

Mira lives in the **menu bar** (it has no Dock icon). On first launch:

| macOS asks for | Why | If you said no |
|---|---|---|
| **Local Network** | to find adapters and talk to them | System Settings → Privacy & Security → Local Network → enable Mira. *Without it the display list just stays empty, because macOS reports no error.* |
| **Screen & System Audio Recording** (when you first mirror) | to capture the screen and sound | System Settings → Privacy & Security → Screen & System Audio Recording → enable Mira, then quit and reopen it. |
| **Incoming connections** (firewall, if on) | the adapter connects *into* your Mac on TCP 7236 | System Settings → Network → Firewall → Options → allow Mira. |

Then click the menu bar icon, pick your display and click **Mirror**. If the adapter isn't listed, type its IP address. You can find it in your router's device list.

**Command line:** the same binary is a CLI. It's handy for diagnosing a new setup because it logs everything:

```bash
sudo ln -s /Applications/Mira.app/Contents/MacOS/Mira /usr/local/bin/mira   # optional
mira doctor                          # checks permissions, firewall, ports, network
mira list                            # find adapters on the network
mira connect 192.168.1.42            # mirror the screen (Ctrl-C to stop)
mira connect "Living Room"           # …or by (part of) its name
mira connect 192.168.1.42 --test-pattern --verbose
mira displays                        # pick a screen with --display <n>
mira help                            # all options
```

### Settings

| Setting | Default | Notes |
|---|---|---|
| Display | main display | menu or `--display <n>` |
| Resolution | Auto | best of 1080p30 / 720p30 the adapter supports; `--resolution 720p` to force |
| Bitrate | 6 Mbit/s | lower it if the picture stutters, raise it for sharper text |
| Audio | on | AAC if the adapter supports it, else LPCM; `--audio-codec lpcm` to force |
| Latency buffer | 200 ms (AAC), 150 ms (LPCM), 120 ms (no audio) | `--delay <ms>`; raise it if audio crackles |

## Build from source

Requires Xcode 16+ (Swift 5.9+).

```bash
make build        # debug build → .build/debug/Mira
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
mira doctor                                                # 1. fix anything with ⚠️
mira list                                                  # 2. adapter should be listed
mira connect <ip> --test-pattern --no-audio --verbose      # 3. simplest stream
mira connect <ip> --test-pattern --verbose                 # 4. + audio (beep each second)
mira connect <ip>                                          # 5. real screen + audio
```

What success looks like at step 3:

```
[MICE] → SOURCE_READY
[RTSP] Sink connected from 192.168.1.42          ← the adapter connected back (firewall OK)
[RTSP] ← 200 OK … M1 / M3 / M4 / M5              ← capability negotiation
[RTSP] Sink H.264 profile …, CEA: …              ← what the adapter supports
[RTSP] ← SETUP / PLAY
[Mira] ✅ Mirroring to … at 1920x1080p30
```

The TV should show colour bars with a moving white line and a running frame counter.

### If it fails: where and why

| Symptom in the log | Likely cause | Try |
|---|---|---|
| `list` finds nothing | Local Network permission off, adapter not on Wi-Fi, different subnet, or mDNS filtered | Check System Settings → Privacy & Security → Local Network. Re-check the setup steps. `dns-sd -B _display._tcp`. Connect by IP (find it in your router's DHCP list) |
| `Could not reach … :7250 … Connection refused` | not a 4K adapter, or infrastructure mode off | Check the model and firmware |
| `Sink did not connect back to the RTSP port within 15s` | **macOS firewall**, or the adapter rejected SOURCE_READY (PIN required?) | `Mira doctor`. Turn the firewall off briefly to test. Disable the PIN in the adapter app |
| `Sink rejected M4 …` | the chosen format was refused | `--resolution 720p`, then `--no-audio` |
| Handshake OK but black screen | the media stream isn't accepted | `--no-audio`, `--resolution 720p`, `--bitrate 4`. Check `--dump-ts out.ts` plays in `ffplay` |
| Picture stutters or freezes | Wi-Fi throughput or jitter | `--bitrate 4`, `--delay 300`, move closer to the router |
| Audio crackles or drops | audio arrives too late | `--delay 300`. Try `--audio-codec lpcm` |
| Handshake OK, no sound | adapter dislikes AAC | `--audio-codec lpcm` |

**Please send `~/Library/Logs/Mira/mira.log` from the first real test.** It contains every MICE/RTSP message exchanged with the adapter, including its exact capabilities. That's the information needed to fix anything adapter-specific.

### Recording what the adapter does (optional, very useful)

```bash
sudo tcpdump -i en0 -w mira-adapter.pcap host <adapter-ip>   # in a second terminal while connecting
```

If you have a Windows PC, also capture a session from Windows → adapter in the same way. A side-by-side comparison of the RTSP exchange shows exactly what the adapter expects.

---

## Testing without hardware

`tools/mock_sink.py` is a scripted MICE sink. It listens on 7250, connects back for RTSP, plays the sink side of M1–M8, and checks every RTP/TS packet (sequence numbers, continuity counters, PAT/PMT, PCR interval, and whether each PES arrives before its presentation time).

```bash
make e2e                                               # automated: handshake + stream validation + ffmpeg decode
MIRA_ARGS="" tools/e2e.sh                              # same, capturing the real screen
python3 tools/mock_sink.py --play                      # interactive: watch the stream in ffplay
.build/debug/Mira connect 127.0.0.1                    # …in a second terminal
python3 tools/mock_sink.py --advertise "Fake TV"       # appears in `Mira list` and the menu bar app
python3 tools/mock_sink.py --help                      # --no-audio, --no-m2, --video-formats, --idr-at, …
```

The mock sink is written from the same specs as Mira, so it can't catch a shared misreading of them. ffmpeg's independent decode check and the real adapter cover that.

## How it works

| Layer | File | Notes |
|---|---|---|
| Discovery | `Discovery/DeviceBrowser.swift` | DNS-SD `_display._tcp` with TXT `container_id`, resolved per interface (works with a VPN connected) |
| MICE | `Session/MICEMessage.swift`, `MICEClient.swift` | SOURCE_READY / STOP_PROJECTION; friendly name is UTF-16LE with BOM, as Windows and GNOME send it |
| RTSP/WFD | `Session/WFDSession.swift`, `WFDNegotiation.swift` | Mac is the RTSP server; M1–M8, M16 keep-alive every 25 s, IDR requests, PAUSE/PLAY |
| Capture | `Capture/ScreenCapturer.swift` | ScreenCaptureKit video + system audio, letterboxed to 16:9 |
| Video | `Encoder/H264Encoder.swift`, `H264Bitstream.swift` | VideoToolbox H.264 Baseline (CBP-flagged), no B-frames, IDR every 2 s or on request, AUD + SPS/PPS per keyframe |
| Audio | `Encoder/AACEncoder.swift`, `LPCMEncoder.swift` | AAC-LC 48 kHz stereo 128 kbit/s (ADTS), or WFD LPCM 16-bit big-endian |
| Mux | `Mux/MPEGTSMuxer.swift` | WFD PIDs (PMT 0x100, video 0x1011, audio 0x1100), PCR on video, PAT/PMT every 100 ms |
| Transport | `RTP/RTPMP2TPacketizer.swift`, `RTPSender.swift` | RTP payload type 33, 7 TS packets per datagram |
| Timing | `MediaPipeline.swift` | constant-rate frame pump (re-sends the last frame on a static screen), PTS = capture + buffer, PCR backstop on audio |

References: [MS-MICE], Wi-Fi Display Technical Specification, Android's open-source Wi-Fi Display source (LPCM layout), ISO/IEC 13818-1 (MPEG-TS), RFC 2250 (MPEG-TS over RTP), and [GNOME Network Displays], an open-source MICE source that was invaluable for byte-level details.

## Releasing

1. Add a `## [x.y.z]` section to `CHANGELOG.md` and commit.
2. `make release VERSION=x.y.z` bumps `Support/Info.plist`, commits and tags.
3. `git push && git push origin vx.y.z`. GitHub Actions tests, builds the universal app, and publishes a release with the DMG, zip, checksums and Homebrew cask. Versions with a suffix (`-beta.1`) become pre-releases.

**Signed + notarized releases:** add the repository secrets `MACOS_CERTIFICATE` (base64 Developer ID Application `.p12`), `MACOS_CERTIFICATE_PWD`, `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_PASSWORD`. The workflow then signs with the Developer ID and notarizes automatically, and the Gatekeeper step above goes away.

**Homebrew:** each release includes `mira.rb`. Put it in a tap repo (`eliasthecactus/homebrew-tap`, file `Casks/mira.rb`) and users can `brew install --cask eliasthecactus/tap/mira`.

## Not implemented (yet)

- Stream encryption (MICE DTLS / HDCP) and PIN pairing. Most adapters don't require them for infrastructure mode.
- UIBC (sending touch/keyboard input back from the TV)
- Extending the desktop to the TV as a second display (needs a virtual display driver)
- Notarized builds out of the box. Supported by the release workflow once Developer ID secrets are added.

[MS-MICE]: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-mice/940d808c-97f8-418e-a8a9-c471dc0d21bb
[GNOME Network Displays]: https://gitlab.gnome.org/GNOME/gnome-network-displays

## License

MIT — see [LICENSE](LICENSE).
