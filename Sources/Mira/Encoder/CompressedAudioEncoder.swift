import Foundation
import AudioToolbox

// PCM (interleaved Float32, 48 kHz stereo) -> compressed audio frames:
//   .aac:  AAC-LC wrapped in ADTS, how AAC is carried in MPEG-TS (stream_type 0x0F).
//          WFD's AAC mode bit 0 is exactly this format.
//   .opus: raw Opus packets of 20 ms, the one audio codec every Cast receiver supports.
final class CompressedAudioEncoder: @unchecked Sendable {   // used only from MediaPipeline.audioQueue

    enum Codec: String { case aac = "AAC", opus = "Opus" }

    static let sampleRate = 48_000.0
    static let channels: UInt32 = 2

    let codec: Codec
    let framesPerPacket: Int
    private(set) var primingFrames: Int         // encoder delay (AAC 2112, Opus ~312)

    // (frame, presentation time in host-clock seconds)
    var onEncoded: ((_ frame: Data, _ pts: Double) -> Void)?

    private var converter: AudioConverterRef?
    private var fifo: [Float] = []             // interleaved L R L R ...
    private var timelineStart: Double?         // host time of the first frame fed
    private var framesQueued = 0               // frames ever appended to the fifo
    private var packetsOut = 0
    private let feed: UnsafeMutablePointer<Float>
    private var feedFramesAvailable = 0
    private var maxOutputPacketSize: UInt32 = 1536
    private static let noDataStatus: OSStatus = 0x6E6F6474  // 'nodt'

    static let pcmFormat = AudioStreamBasicDescription(
        mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
        mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)

    static func compressedFormat(_ codec: Codec) -> AudioStreamBasicDescription {
        switch codec {
        case .aac:
            return AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: AudioFormatFlags(MPEG4ObjectID.AAC_LC.rawValue),
                mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        case .opus:
            return AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
                mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        }
    }

    // Whether this Mac can encode Opus (AudioToolbox).
    static let opusAvailable: Bool = {
        var input = pcmFormat
        var output = compressedFormat(.opus)
        var conv: AudioConverterRef?
        let ok = AudioConverterNew(&input, &output, &conv) == noErr && conv != nil
        if let conv { AudioConverterDispose(conv) }
        return ok
    }()

    init(codec: Codec = .aac, bitrate: UInt32 = 128_000) throws {
        self.codec = codec
        var input = Self.pcmFormat
        var output = Self.compressedFormat(codec)
        framesPerPacket = Int(output.mFramesPerPacket)
        feed = UnsafeMutablePointer<Float>.allocate(capacity: framesPerPacket * 2)
        primingFrames = codec == .aac ? 2112 : 0

        var conv: AudioConverterRef?
        let status = AudioConverterNew(&input, &output, &conv)
        guard status == noErr, let conv else {
            feed.deallocate()
            throw EncoderError.converterCreationFailed(status)
        }
        converter = conv

        var br = bitrate
        AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &br)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var maxSize: UInt32 = 0
        if AudioConverterGetProperty(conv, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maxSize) == noErr, maxSize > 0 {
            maxOutputPacketSize = maxSize
        }
        if codec == .opus {
            var prime = AudioConverterPrimeInfo()
            var primeSize = UInt32(MemoryLayout<AudioConverterPrimeInfo>.size)
            if AudioConverterGetProperty(conv, kAudioConverterPrimeInfo, &primeSize, &prime) == noErr {
                primingFrames = Int(prime.leadingFrames)
            }
        }
        Log.info("Audio", "\(codec == .aac ? "AAC-LC" : "Opus") encoder 48 kHz stereo \(bitrate / 1000) kbps")
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        feed.deallocate()
    }

    // Appends interleaved stereo frames captured at host time `pts` (seconds).
    func encode(interleaved samples: [Float], pts: Double) {
        let frames = samples.count / 2
        guard frames > 0 else { return }

        if let start = timelineStart {
            let expected = start + Double(framesQueued) / Self.sampleRate
            let drift = pts - expected
            if drift > 1.0 || drift < -1.0 {
                Log.info("Audio", String(format: "Audio timeline jump %.2fs - resetting encoder", drift))
                reset(at: pts)
            } else if drift > 0.04 {
                // Capture gap (SCStream stops delivering during silence): pad with silence.
                let pad = Int(drift * Self.sampleRate)
                fifo.append(contentsOf: [Float](repeating: 0, count: pad * 2))
                framesQueued += pad
            }
        } else {
            reset(at: pts)
        }

        fifo.append(contentsOf: samples)
        framesQueued += frames
        drain()
    }

    private func reset(at pts: Double) {
        if let converter { AudioConverterReset(converter) }
        fifo.removeAll(keepingCapacity: true)
        timelineStart = pts
        framesQueued = 0
        packetsOut = 0
    }

    private func drain() {
        guard let converter, let start = timelineStart else { return }
        let outBuf = UnsafeMutableRawPointer.allocate(byteCount: Int(maxOutputPacketSize), alignment: 16)
        defer { outBuf.deallocate() }

        while fifo.count >= framesPerPacket * 2 {
            fifo.withUnsafeBufferPointer { src in
                feed.update(from: src.baseAddress!, count: framesPerPacket * 2)
            }
            fifo.removeFirst(framesPerPacket * 2)
            feedFramesAvailable = framesPerPacket

            // Pull output until this chunk is consumed.
            while true {
                var packets: UInt32 = 1
                var desc = AudioStreamPacketDescription()
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: Self.channels, mDataByteSize: maxOutputPacketSize, mData: outBuf))
                let status = AudioConverterFillComplexBuffer(
                    converter, { _, ioPackets, ioData, _, userData in
                        let enc = Unmanaged<CompressedAudioEncoder>.fromOpaque(userData!).takeUnretainedValue()
                        return enc.provideInput(ioPackets, ioData)
                    },
                    Unmanaged.passUnretained(self).toOpaque(), &packets, &list, &desc)

                if packets > 0 {
                    let size = Int(list.mBuffers.mDataByteSize)
                    let index = packetsOut
                    packetsOut += 1
                    // The first packets only carry encoder priming; skip them so every
                    // emitted frame has a non-negative timestamp on our timeline.
                    if (index + 1) * framesPerPacket > primingFrames {
                        var frame = Data()
                        if codec == .aac { frame.append(contentsOf: Self.adtsHeader(payloadLength: size)) }
                        frame.append(Data(bytes: outBuf, count: size))
                        let pts = start + Double(index * framesPerPacket - primingFrames) / Self.sampleRate
                        onEncoded?(frame, pts)
                    }
                }
                if status != noErr && status != Self.noDataStatus {
                    Log.warn("Audio", "AudioConverterFillComplexBuffer error \(status)")
                    return
                }
                if feedFramesAvailable == 0 && packets == 0 { break }
                if feedFramesAvailable == 0 && status == Self.noDataStatus { break }
            }
        }
    }

    private func provideInput(_ ioPackets: UnsafeMutablePointer<UInt32>,
                              _ ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard feedFramesAvailable > 0 else {
            ioPackets.pointee = 0
            return Self.noDataStatus
        }
        ioPackets.pointee = UInt32(feedFramesAvailable)
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = Self.channels
        ioData.pointee.mBuffers.mDataByteSize = UInt32(feedFramesAvailable * 8)
        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(feed)
        feedFramesAvailable = 0
        return noErr
    }

    // 7-byte ADTS header, no CRC: AAC-LC, 48 kHz (index 3), 2 channels.
    static func adtsHeader(payloadLength: Int) -> [UInt8] {
        let frameLength = payloadLength + 7
        let profile = 1          // AAC LC (object type 2) - 1
        let freqIndex = 3        // 48000 Hz
        let channelConfig = 2
        return [
            0xFF,
            0xF1,                                                       // MPEG-4, layer 0, no CRC
            UInt8((profile << 6) | (freqIndex << 2) | (channelConfig >> 2)),
            UInt8(((channelConfig & 0x3) << 6) | (frameLength >> 11)),
            UInt8((frameLength >> 3) & 0xFF),
            UInt8(((frameLength & 0x7) << 5) | 0x1F),
            0xFC,
        ]
    }

    enum EncoderError: Error {
        case converterCreationFailed(OSStatus)
    }
}
